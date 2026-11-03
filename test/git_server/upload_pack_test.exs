defmodule GitServer.UploadPackTest do
  # Repositories seeded in the store with packs real git wrote, read with the real git
  # client. Requests that client never sends go through Plug.Test.
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import GitServer.TestGit
  import Plug.Conn, only: [put_req_header: 3]

  alias GitServer.{
    GitFixture,
    ObjectId,
    PackBuilder,
    PktLine,
    Repository,
    Seed,
    Store,
    TestServer
  }

  @moduletag :tmp_dir

  defp clone!(server, name, tmp_dir, dir \\ "clone") do
    path = Path.join(tmp_dir, dir)
    {_, 0} = git(["clone", "-q", TestServer.url(server, name), path])
    path
  end

  defp rev_parse!(dir, rev) do
    {output, 0} = git(["rev-parse", rev], cd: dir)
    String.trim(output)
  end

  defp assert_fsck_clean(dir) do
    assert {output, 0} = git(["fsck", "--full", "--strict"], cd: dir)
    refute output =~ ~r/error|missing/
  end

  describe "with the real git client" do
    test "a clone is identical to the source", %{tmp_dir: tmp_dir} do
      source = GitFixture.build!(Path.join(tmp_dir, "source"))
      server = TestServer.start!()
      Seed.push!(server.store, "fixture", source)

      clone = clone!(server, "fixture.git", tmp_dir)

      assert_fsck_clean(clone)
      assert rev_parse!(clone, "HEAD") == Seed.rev_parse!(source, "HEAD")
      assert rev_parse!(clone, "v1") == Seed.rev_parse!(source, "v1")
      assert {_, 0} = System.cmd("diff", ["-r", "-x", ".git", "-x", "sub", source.repo, clone])

      {objects, 0} = git(["rev-list", "--objects", "--all"], cd: clone)
      {source_objects, 0} = git(["rev-list", "--objects", "--all"], cd: source.repo)
      assert objects == source_objects
    end

    test "a pull fetches only the new objects", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      first = Seed.commit!(source, "file", "one\n")
      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)
      clone = clone!(server, "repo", tmp_dir)

      second = Seed.commit!(source, "file", "two\n")
      Seed.push!(server.store, "repo", source, [second, "^" <> first])

      # A commit, its tree and the file: git passes on the count from the pack's header.
      {output, 0} = git(["pull"], cd: clone, env: [{"GIT_TRACE", "1"}])
      assert output =~ "--pack_header=2,3\n"
      assert output =~ "Fast-forward"
      assert File.read!(Path.join(clone, "file")) == "two\n"
      assert rev_parse!(clone, "HEAD") == second
      assert_fsck_clean(clone)
    end

    test "fetching tags, explicitly and followed", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      Seed.commit!(source, "file", "one\n")
      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)
      clone = clone!(server, "repo", tmp_dir)

      second = Seed.commit!(source, "file", "two\n")
      {_, 0} = git(["tag", "-a", "annotated", "-m", "a tag"], cd: source.repo)
      {_, 0} = git(["tag", "light"], cd: source.repo)
      Seed.push!(server.store, "repo", source, ["--all", "--not", second <> "~1"])

      {_, 0} = git(["fetch", "-q", "origin", "refs/tags/light:refs/tags/light"], cd: clone)
      assert rev_parse!(clone, "light") == second

      # A fetch of the branch follows the annotated tag.
      {_, 0} = git(["fetch", "-q", "origin"], cd: clone)
      assert rev_parse!(clone, "annotated") == Seed.rev_parse!(source, "annotated")
      assert rev_parse!(clone, "annotated^{commit}") == second
      assert_fsck_clean(clone)
    end

    test "refs spread across three packs", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      first = Seed.commit!(source, "file", "one\n")
      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)

      {_, 0} = git(["checkout", "-q", "-b", "side"], cd: source.repo)
      side = Seed.commit!(source, "side", "side\n")
      Seed.push!(server.store, "repo", source, [side, "^" <> first])

      {_, 0} = git(["checkout", "-q", "main"], cd: source.repo)
      main = Seed.commit!(source, "main", "main\n")
      Seed.push!(server.store, "repo", source, [main, "^" <> first])

      {:ok, state, _} = Repository.read_state(server.store, "repo")
      assert length(state.packs) == 3

      clone = clone!(server, "repo", tmp_dir)
      assert rev_parse!(clone, "origin/side") == side
      assert rev_parse!(clone, "origin/main") == main
      assert File.exists?(Path.join(clone, "main"))
      assert_fsck_clean(clone)
    end

    test "a want must be reachable from a ref", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      first = Seed.commit!(source, "file", "one\n")
      second = Seed.commit!(source, "file", "two\n")
      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)

      # A commit in a listed pack that no ref points to.
      {_, 0} = git(["checkout", "-q", "-b", "orphan"], cd: source.repo)
      orphan = Seed.commit!(source, "orphan", "orphan\n")
      Seed.push_pack_only!(server.store, "repo", source, [orphan, "^" <> second])

      clone = Path.join(tmp_dir, "clone")
      {_, 0} = git(["init", "-q", clone])
      url = TestServer.url(server, "repo")

      {output, 128} = git(["fetch", url, orphan], cd: clone)
      assert output =~ "not our ref #{orphan}"
      {output, 128} = git(["fetch", url, String.duplicate("1", 40)], cd: clone)
      assert output =~ "not our ref"

      # An ancestor of a tip is reachable, though no ref names it.
      {_, 0} = git(["fetch", "-q", url, first], cd: clone)
      assert rev_parse!(clone, "FETCH_HEAD") == first
      assert_fsck_clean(clone)
      assert {_, status} = git(["cat-file", "-e", orphan], cd: clone)
      assert status != 0
    end

    test "ls-refs peels annotated tags, and needs no pack to list branches", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      commit = Seed.commit!(source, "file", "one\n")
      {_, 0} = git(["tag", "light"], cd: source.repo)
      {_, 0} = git(["tag", "-a", "v1", "-m", "a tag"], cd: source.repo)
      {_, 0} = git(["tag", "-a", "v2", "-m", "a tag of a tag", "v1"], cd: source.repo)
      server = TestServer.start!()
      pack = Seed.push!(server.store, "repo", source)
      v1 = Seed.rev_parse!(source, "v1")
      v2 = Seed.rev_parse!(source, "v2")
      url = TestServer.url(server, "repo")

      assert git(["ls-remote", url]) ==
               {"""
                #{commit}\tHEAD
                #{commit}\trefs/heads/main
                #{commit}\trefs/tags/light
                #{v1}\trefs/tags/v1
                #{commit}\trefs/tags/v1^{}
                #{v2}\trefs/tags/v2
                #{commit}\trefs/tags/v2^{}
                """, 0}

      :ok = Store.delete(server.store, Repository.pack_key("repo", pack))
      assert git(["ls-remote", "--heads", url]) == {"#{commit}\trefs/heads/main\n", 0}
    end

    test "ls-refs leaves a tag chain longer than the bound unpeeled", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      commit = Seed.commit!(source, "file", "one\n")
      max = GitServer.Object.max_peel()

      # t1 tags the commit, and each tag after it the one before.
      for n <- 1..(max + 1) do
        target = if n == 1, do: "HEAD", else: "t#{n - 1}"

        {_, 0} =
          git(["-c", "advice.nestedTag=false", "tag", "-a", "t#{n}", "-m", "t#{n}", target],
            cd: source.repo
          )
      end

      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)
      url = TestServer.url(server, "repo")

      {output, 0} = git(["ls-remote", url, "refs/tags/t#{max}*"])
      assert output =~ "#{commit}\trefs/tags/t#{max}^{}\n"
      {output, 0} = git(["ls-remote", url, "refs/tags/t#{max + 1}*"])
      assert output == "#{Seed.rev_parse!(source, "t#{max + 1}")}\trefs/tags/t#{max + 1}\n"
    end

    test "a pack index that doesn't match its pack fails a fetch and a push, logged",
         %{tmp_dir: tmp_dir} do
      source = Seed.source!(Path.join(tmp_dir, "a"))
      Seed.commit!(source, "file", "one\n")
      other = Seed.source!(Path.join(tmp_dir, "b"))
      Seed.commit!(other, "file", "two\n")
      server = TestServer.start!()
      pack = Seed.push!(server.store, "repo", source)
      other_pack = Seed.push!(server.store, "other", other)
      {:ok, idx, _etag} = Store.get(server.store, Repository.idx_key("other", other_pack))
      {:ok, _} = Store.put(server.store, Repository.idx_key("repo", pack), idx, :none)
      url = TestServer.url(server, "repo")

      log =
        capture_log(fn ->
          {output, 128} = git(["clone", "-q", url, Path.join(tmp_dir, "clone")])
          assert output =~ "500"
        end)

      assert log =~ "repository repo: pack #{pack}.pack: pack index doesn't match pack"

      log =
        capture_log(fn ->
          Seed.commit!(source, "file", "three\n")
          {output, 1} = git(["push", url, "main"], cd: source.repo)
          assert output =~ "storage error"
        end)

      assert log =~ "repository repo: pack #{pack}.pack: pack index doesn't match pack"
    end

    test "a fetch over its work budget fails, logged", %{tmp_dir: tmp_dir} do
      # Small blobs, each a delta of one base too big for the cache, so every read
      # inflates the base again for a few bytes of output.
      big = String.duplicate("x", 40_000_000)
      base_id = GitServer.Object.id(:blob, big)
      blobs = for n <- 1..10, do: {"f#{n}", "small #{n}\n"}

      tree =
        blobs
        |> Enum.sort()
        |> Enum.map_join(fn {name, content} ->
          "100644 #{name}\0" <> GitServer.Object.id(:blob, content)
        end)

      tree_id = GitServer.Object.id(:tree, tree)

      commit =
        "tree #{ObjectId.to_hex(tree_id)}\nauthor A <a@example.com> 0 +0000\n" <>
          "committer A <a@example.com> 0 +0000\n\nhostile\n"

      {pack, idx_entries} =
        PackBuilder.build(
          [
            PackBuilder.object(:commit, commit),
            PackBuilder.object(:tree, tree),
            PackBuilder.object(:blob, big),
          ] ++
            for {_name, content} <- blobs do
              PackBuilder.ref_delta(
                GitServer.Object.id(:blob, content),
                base_id,
                PackBuilder.insert_delta(40_000_000, content)
              )
            end
        )

      checksum = binary_part(pack, byte_size(pack) - 20, 20)
      name = ObjectId.to_hex(checksum)
      server = TestServer.start!(max_fetch_work_bytes: 100_000_000)
      {:ok, _} = Store.put(server.store, Repository.pack_key("repo", name), pack, :none)

      {:ok, _} =
        Store.put(
          server.store,
          Repository.idx_key("repo", name),
          GitServer.Pack.Idx.encode(idx_entries, checksum),
          :none
        )

      commit_hex = ObjectId.to_hex(GitServer.Object.id(:commit, commit))

      state = %GitServer.State{
        head: "refs/heads/main",
        refs: %{"refs/heads/main" => commit_hex},
        packs: [name],
      }

      {:ok, _} = Repository.put_state(server.store, "repo", state, :absent)

      log =
        capture_log(fn ->
          {output, 128} =
            git(["clone", "-q", TestServer.url(server, "repo"), Path.join(tmp_dir, "clone")])

          assert output =~ "too much work resolving delta bases"
        end)

      assert log =~ "repository repo: pack #{name}.pack: too much work resolving delta bases"
      assert length(String.split(log, "too much work")) == 2
    end

    test "large compressible blobs clone under the default work budget", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)

      for name <- ~w(a b c) do
        Seed.commit!(source, name, String.duplicate(name <> "012345678", 4_000_000))
      end

      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)
      clone = clone!(server, "repo", tmp_dir)
      assert File.stat!(Path.join(clone, "c")).size == 40_000_000
      assert_fsck_clean(clone)
    end

    test "a large file changed many times clones on the work allowance alone",
         %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      # Too big for the base cache, so every version resolves its delta base again.
      lines = for i <- 1..800_000, do: "line #{i} of a large data file, padded out\n"

      for round <- 1..8 do
        Seed.commit!(source, "data", List.replace_at(lines, round * 1000, "round #{round}\n"))
      end

      server = TestServer.start!(max_fetch_work_bytes: 1)
      Seed.push!(server.store, "repo", source)
      clone = clone!(server, "repo", tmp_dir)
      assert File.stat!(Path.join(clone, "data")).size > 32_000_000
      assert_fsck_clean(clone)
    end

    test "a request too big for one POST, probed first", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      Seed.commit!(source, "file", "one\n")
      {_, 0} = git(["tag", "base"], cd: source.repo)

      # One want each: more bytes than this http.postBuffer, near the smallest git allows.
      commits = for i <- 1..1500, do: commit_stream(i)
      input = Path.join(tmp_dir, "fast-import")
      File.write!(input, commits)
      GitServer.LocalGit.git!(source.home, source.repo, ["fast-import", "--quiet"], input: input)

      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)
      clone = Path.join(tmp_dir, "clone")

      assert {_, 0} =
               git([
                 "-c",
                 "http.postBuffer=65600",
                 "clone",
                 "-q",
                 TestServer.url(server, "repo"),
                 clone,
               ])

      assert rev_parse!(clone, "origin/b1500") == Seed.rev_parse!(source, "b1500")
    end

    defp commit_stream(i) do
      message = "branch #{i}"

      """
      commit refs/heads/b#{i}
      committer Test User <test@example.com> 1700000000 +0000
      data #{byte_size(message)}
      #{message}
      from refs/tags/base

      """
    end

    test "many haves arrive gzipped, over several rounds", %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      first = Seed.commit!(source, "file", "one\n")
      server = TestServer.start!()
      Seed.push!(server.store, "repo", source)
      clone = clone!(server, "repo", tmp_dir)

      for i <- 1..60 do
        {_, 0} = git(["commit", "-q", "--allow-empty", "-m", "local #{i}"], cd: clone)
      end

      second = Seed.commit!(source, "file", "two\n")
      Seed.push!(server.store, "repo", source, [second, "^" <> first])

      {output, 0} =
        git(["fetch", "origin"],
          cd: clone,
          env: [{"GIT_TRACE_CURL", "1"}, {"GIT_TRACE_PACKET", "1"}]
        )

      assert output =~ ~r/Send header: Content-Encoding: gzip/i
      assert output =~ "fetch< NAK"
      assert output =~ "fetch< ready"
      assert rev_parse!(clone, "origin/main") == second
      assert_fsck_clean(clone)
    end
  end

  describe "fetch requests" do
    setup %{tmp_dir: tmp_dir} do
      source = Seed.source!(tmp_dir)
      first = Seed.commit!(source, "file", "one\n")
      second = Seed.commit!(source, "file", "two\n")
      store = GitServer.TestStore.fresh()
      Seed.push!(store, "repo", source)
      temp_dir = Path.join(tmp_dir, "requests")
      File.mkdir_p!(temp_dir)

      %{
        first: first,
        second: second,
        store: store,
        temp_dir: temp_dir,
        opts: [store: store, temp_dir: temp_dir, authorize: fn _ -> :ok end],
      }
    end

    defp fetch(opts, arguments, repo \\ "repo") do
      body = [
        PktLine.encode("command=fetch\n"),
        PktLine.encode("object-format=sha1\n"),
        PktLine.delim(),
        Enum.map(arguments, &PktLine.encode(&1 <> "\n")),
        PktLine.flush(),
      ]

      conn =
        Plug.Test.conn(:post, "/#{repo}/git-upload-pack", IO.iodata_to_binary(body))
        |> put_req_header("git-protocol", "version=2")
        |> GitServer.Plug.call(GitServer.Plug.init(opts))

      assert conn.status == 200
      assert {:ok, packets} = PktLine.decode(conn.resp_body)

      assert Plug.Conn.get_resp_header(conn, "content-type") == [
               "application/x-git-upload-pack-result",
             ]

      packets
    end

    # The object count in a pack's header, after checking its trailer, from data packets.
    defp pack_count(packets) do
      data = for <<1, data::binary>> <- packets, into: <<>>, do: data
      size = byte_size(data) - ObjectId.size()
      <<pack::binary-size(size), trailer::binary>> = data
      assert ObjectId.hash(pack) == trailer
      <<"PACK", 2::32, count::32, _::binary>> = pack
      count
    end

    test "with done, only the packfile section", %{opts: opts, first: first, second: second} do
      assert ["packfile\n" | rest] = fetch(opts, ["want #{second}", "done"])
      assert List.last(rest) == :flush
      assert pack_count(rest) == 6

      assert ["packfile\n" | rest] =
               fetch(
                 opts,
                 ["want #{second}", "have #{first}", "thin-pack", "no-progress"] ++
                   ["include-tag", "ofs-delta", "done"]
               )

      assert pack_count(rest) == 3

      # Everything wanted is already there: a valid, empty pack.
      assert ["packfile\n" | rest] = fetch(opts, ["want #{first}", "have #{second}", "done"])
      assert pack_count(rest) == 0
    end

    test "without done, a known have means ready", %{opts: opts, first: first, second: second} do
      unknown = String.duplicate("1", 40)

      assert [
               "acknowledgments\n",
               "ACK " <> ack,
               "ready\n",
               :delim,
               "packfile\n" | rest
             ] = fetch(opts, ["want #{second}", "have #{unknown}", "have #{first}"])

      assert ack == first <> "\n"
      assert pack_count(rest) == 3
    end

    test "without done or a known have, a NAK", %{opts: opts, second: second} do
      nak = ["acknowledgments\n", "NAK\n", :flush]
      assert fetch(opts, ["want #{second}"]) == nak
      assert fetch(opts, ["want #{second}", "have #{String.duplicate("1", 40)}"]) == nak
    end

    test "bad requests get an ERR packet", %{opts: opts, second: second} do
      for {arguments, message} <- [
            {[], "ERR fetch needs at least one want"},
            {["done"], "ERR fetch needs at least one want"},
            {["want abc"], "ERR malformed want"},
            {["want #{String.duplicate("z", 40)}"], "ERR malformed want"},
            {["want #{second}", "have abc"], "ERR malformed have"},
            {["want #{second}", "filter blob:none"], "ERR unsupported fetch argument"},
            {["want #{second}", "deepen 1"], "ERR unsupported fetch argument"},
            {["want #{second}", "sideband-all"], "ERR unsupported fetch argument"},
            {["want #{String.duplicate("1", 40)}", "done"], "ERR upload-pack: not our ref"},
          ] do
        assert [packet] = fetch(opts, arguments)
        assert String.starts_with?(packet, message), inspect({arguments, packet})
      end
    end

    test "an object over the cap fails the pack on band 3",
         %{opts: opts, store: store} = context do
      source = Seed.source!(Path.join(context.tmp_dir, "big"))
      big = Seed.commit!(source, "file", String.duplicate("x", 2000))
      Seed.push!(store, "big", source)

      opts = [max_object_bytes: 1000] ++ opts

      log =
        capture_log(fn ->
          assert ["packfile\n" | rest] = fetch(opts, ["want #{big}", "done"], "big")
          assert List.last(rest) == :flush

          assert [<<3, "git_server: object too large\n">>] =
                   for(<<3, _::binary>> = p <- rest, do: p)
        end)

      assert log =~ ~r/repository big: pack [0-9a-f]{40}\.pack: object too large/
      assert File.ls!(context.temp_dir) == []
    end

    test "request files are gone afterwards", %{opts: opts, temp_dir: temp_dir, second: second} do
      for arguments <- [
            ["want #{second}", "done"],
            ["want #{second}"],
            ["want #{"1" |> String.duplicate(40)}"],
          ] do
        fetch(opts, arguments)
        assert File.ls!(temp_dir) == []
      end
    end
  end
end
