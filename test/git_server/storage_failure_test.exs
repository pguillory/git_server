defmodule GitServer.StorageFailureTest do
  # Storage the server can't use: a bucket that refuses its credentials, packs missing,
  # corrupt or over this server's limits, and a pack cache directory it can't make.
  # The bucket is outside the library's control, so these tests write such data to it
  # directly. Every one is answered without the data and logged, so the operator can
  # fix it. Includes the README's "When something goes wrong" rows for storage.
  #
  # Not async: each test captures the log, which must hold only its own lines.
  use ExUnit.Case, async: false
  import Bitwise
  import ExUnit.CaptureLog
  import GitServer.TestGit
  alias GitServer.Object
  alias GitServer.ObjectId
  alias GitServer.PackBuilder
  alias GitServer.Repository
  alias GitServer.Seed
  alias GitServer.State
  alias GitServer.Store
  alias GitServer.TestServer
  alias GitServer.Pack.Idx

  @moduletag :tmp_dir

  defp init!(dir) do
    {_, 0} = git(["init", "-q", "-b", "main", dir])
    dir
  end

  defp commit!(dir, file, content) do
    File.write!(Path.join(dir, file), content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", "change #{file}"], cd: dir)
  end

  defp clone(server, tmp_dir, repo \\ "repo") do
    dir = Path.join(tmp_dir, "clone-#{System.unique_integer([:positive])}")
    git(["clone", "-q", TestServer.url(server, repo), dir])
  end

  defp push(server, local, refspec \\ "main") do
    git(["push", TestServer.url(server, "repo"), refspec], cd: local)
  end

  defp state(store, repo) do
    {:ok, %State{} = state, _etag} = Repository.read_state(store, repo)
    state
  end

  test "storage failures, at each step", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    commit!(local, "a", "a\n")
    {_, 0} = push(server, local)
    commit!(local, "b", "b\n")
    [pack] = state(server.store, "repo").packs

    # A store whose credentials the bucket refuses fails every call.
    {module, config} = server.store
    refused = TestServer.start!(store: {module, %{config | secret_access_key: "wrong"}})

    log =
      capture_log(fn ->
        # The push's ref advertisement, git's first request.
        {output, 128} = push(refused, local)
        assert output =~ "remote: the server's storage failed; try again later\n"
        assert output =~ "The requested URL returned error: 500"

        # ls-refs.
        {output, 128} = clone(refused, tmp_dir)
        assert output =~ "fatal: remote error: the server's storage failed; try again later\n"

        # A pack the state lists is gone from the bucket: the fetch, and the push's
        # download of the repository's packs.
        :ok = Store.delete(server.store, Repository.pack_key("repo", pack))
        {output, 128} = clone(server, tmp_dir)
        assert output =~ "fatal: remote error: the server's storage failed; try again later\n"
        {output, 1} = push(server, local)
        assert output =~ " ! [remote rejected] main -> main (storage failed, try again later)\n"
      end)

    assert log =~ "store error: "
    assert log =~ "pack #{pack} is missing"
    refute log =~ "error] ** "
  end

  test "a stored pack past this server's delta depth or object size", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    lines = for i <- 1..3000, do: "line #{i} of a text file that changes a little each time\n"

    for round <- 1..4 do
      commit!(local, "big.txt", List.replace_at(lines, round * 100, "round #{round}\n"))
    end

    {_, 0} = push(server, local)
    no_deltas = TestServer.start!(store: server.store, max_delta_depth: 0)
    requests = Path.join(tmp_dir, "requests")
    File.mkdir_p!(requests)
    small = TestServer.start!(store: server.store, max_object_bytes: 1000, temp_dir: requests)

    log =
      capture_log(fn ->
        {output, 128} = clone(no_deltas, tmp_dir)
        assert output =~ "delta chain too deep"
      end)

    assert log =~ ~r/repository repo: pack [0-9a-f]{40}\.pack: delta chain too deep/

    log =
      capture_log(fn ->
        {output, 128} = clone(small, tmp_dir)
        assert output =~ "remote: git_server: object too large\n"
      end)

    assert log =~ ~r/repository repo: pack [0-9a-f]{40}\.pack: object too large/
    # The failed fetch's request files are gone.
    assert File.ls!(requests) == []
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
        assert output =~ "fatal: remote error: the server's storage failed; try again later"
      end)

    assert log =~ "repository repo: pack #{pack}.pack: pack index doesn't match pack"

    log =
      capture_log(fn ->
        Seed.commit!(source, "file", "three\n")
        {output, 1} = git(["push", url, "main"], cd: source.repo)
        assert output =~ "storage failed, try again later"
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

        assert output =~ "remote: git_server: too much work resolving delta bases\n"
      end)

    assert log =~ "repository repo: pack #{name}.pack: too much work resolving delta bases"
    assert length(String.split(log, "too much work")) == 2
  end

  test "a pack corrupted in the store is refused and not cached", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    cache_dir = Path.join(tmp_dir, "cache")
    server = TestServer.start!(store: store, pack_cache_dir: cache_dir)
    local = Path.join(tmp_dir, "local")
    {_, 0} = git(["init", "-q", "-b", "main", local])
    commit!(local, "f", "one\n")
    {_, 0} = git(["push", "-q", TestServer.url(server, "r"), "main"], cd: local)

    [name] = state(store, "r").packs
    key = Repository.pack_key("r", name)
    {:ok, pack, _} = Store.get(store, key)
    # One byte changed in the middle: the trailer no longer matches.
    middle = div(byte_size(pack), 2)
    <<head::binary-size(middle), byte, rest::binary>> = pack
    {:ok, _} = Store.put(store, key, <<head::binary, bxor(byte, 1), rest::binary>>, :none)

    log =
      capture_log(fn ->
        {output, status} =
          git(["clone", "-q", TestServer.url(server, "r"), Path.join(tmp_dir, "c")])

        assert status != 0
        assert output =~ "storage"
      end)

    assert log =~ "pack #{name}: pack checksum mismatch"
    assert File.ls!(cache_dir) == []
  end

  test "a cache directory that can't be made is logged and the request goes on",
       %{tmp_dir: tmp_dir} do
    not_a_dir = Path.join(tmp_dir, "file")
    File.write!(not_a_dir, "")
    server = TestServer.start!(pack_cache_dir: not_a_dir)
    local = init!(Path.join(tmp_dir, "local"))
    commit!(local, "a", "a\n")

    log =
      capture_log(fn ->
        {_, 0} = push(server, local)
        {_, 0} = clone(server, tmp_dir)
      end)

    assert log =~ "cannot use the pack cache #{not_a_dir}"
  end

  defp compact(store, tmp_dir, repo, options) do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    GitServer.compact([store: store, authorize: fn _ -> :ok end, temp_dir: work], repo, options)
  end

  # A pack built byte by byte, stored with its idx and listed: its name.
  defp put_built!(store, repo, entries) do
    {pack, idx_entries} = PackBuilder.build(entries)
    checksum = binary_part(pack, byte_size(pack) - 20, 20)
    name = ObjectId.to_hex(checksum)
    {:ok, _} = Store.put(store, Repository.pack_key(repo, name), pack, :none)

    {:ok, _} =
      Store.put(store, Repository.idx_key(repo, name), Idx.encode(idx_entries, checksum), :none)

    {:ok, state, etag} = Repository.read_state(store, repo)
    {:ok, _} = Repository.put_state(store, repo, %{state | packs: state.packs ++ [name]}, etag)
    name
  end

  test "a compaction input whose idx doesn't match its objects fails and publishes nothing",
       %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    good = put_built!(store, "team", [PackBuilder.object(:blob, "good")])
    lying = %{PackBuilder.object(:blob, "real") | id: Object.id(:blob, "claimed")}
    bad = put_built!(store, "team", [lying])

    log =
      capture_log(fn ->
        assert {:error, "compaction failed: " <> _} =
                 compact(store, tmp_dir, "team", max_packs: 0)
      end)

    assert log =~ "repository team: compaction failed"
    assert state(store, "team").packs == [good, bad]
    {:ok, keys} = Store.list(store, "team.git/packs/")
    assert length(keys) == 4
  end

  test "a compaction where no two packs merge within the cap stops", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    x = :crypto.strong_rand_bytes(20_000)
    put_built!(store, "two", [PackBuilder.object(:blob, x)])

    # Deltas on a duplicate of x: written whole, each as big as x.
    deltas =
      for i <- 1..4,
          do: PackBuilder.ofs_delta(Object.id(:blob, x <> "#{i}"), 0, copy_delta(x, "#{i}"))

    put_built!(store, "two", [PackBuilder.object(:blob, x) | deltas])

    log =
      capture_log(fn ->
        assert compact(store, tmp_dir, "two", max_packs: 0, max_compact_bytes: 70_000) ==
                 {:error, "compaction stopped: no two packs merge within :max_compact_bytes"}
      end)

    assert log =~ "repository two: compaction stopped"
  end

  # Copies the whole base, then inserts `tail`.
  defp copy_delta(base, tail) do
    size = byte_size(base)

    PackBuilder.varint(size) <>
      PackBuilder.varint(size + byte_size(tail)) <>
      <<0xF0, band(size, 0xFF), band(size >>> 8, 0xFF), size >>> 16>> <>
      <<byte_size(tail)>> <> tail
  end
end
