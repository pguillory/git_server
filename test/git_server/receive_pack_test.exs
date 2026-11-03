defmodule GitServer.ReceivePackTest do
  # Pushes with the real git client.
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import GitServer.TestGit
  alias GitServer.Repository
  alias GitServer.Store
  alias GitServer.TestServer

  @moduletag :tmp_dir

  defp state(server, repo) do
    {:ok, state, _etag} = Repository.read_state(server.store, repo)
    state
  end

  defp init!(dir, branch \\ "main") do
    {_, 0} = git(["init", "-q", "-b", branch, dir])
    dir
  end

  defp commit!(dir, file, content, message \\ "change") do
    File.write!(Path.join(dir, file), content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", message], cd: dir)
    rev!(dir, "HEAD")
  end

  defp rev!(dir, rev) do
    {id, 0} = git(["rev-parse", rev], cd: dir)
    String.trim(id)
  end

  # A local clone whose origin is the server's repository.
  defp clone!(base, url, dir) do
    {_, 0} = git(["clone", "-q", base, dir])
    {_, 0} = git(["remote", "set-url", "origin", url], cd: dir)
    dir
  end

  # Downloads every listed pack with its idx and checks them with git.
  defp verify_packs!(server, repo, tmp_dir) do
    dir = Path.join(tmp_dir, "verify-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for name <- state(server, repo).packs do
      idx = Path.join(dir, "#{name}.idx")

      {:ok, _} =
        Store.get_file(server.store, Repository.pack_key(repo, name), "#{dir}/#{name}.pack")

      {:ok, _} = Store.get_file(server.store, Repository.idx_key(repo, name), idx)
      {output, 0} = git(["verify-pack", "-v", idx])
      assert output =~ "#{idx |> Path.rootname()}.pack: ok"
    end
  end

  test "the first push to an empty repository", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "README", "hello\n", "first")

    {output, 0} = git(["push", TestServer.url(server, "notes"), "main"], cd: local)
    assert output =~ "* [new branch]      main -> main"

    assert %{head: "refs/heads/main", refs: %{"refs/heads/main" => ^head}, packs: [_]} =
             state(server, "notes")

    verify_packs!(server, "notes", tmp_dir)

    assert git(["ls-remote", TestServer.url(server, "notes")]) ==
             {"#{head}\tHEAD\n#{head}\trefs/heads/main\n", 0}
  end

  test "commits whose blobs delta against each other, pushed in two rounds", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    url = TestServer.url(server, "big")
    lines = for i <- 1..3000, do: "line #{i} of a text file that changes a little each time\n"

    for round <- 1..4 do
      commit!(local, "big.txt", List.replace_at(lines, round * 100, "round #{round}\n"))
    end

    {_, 0} = git(["push", url, "main"], cd: local)

    for round <- 5..8 do
      commit!(local, "big.txt", List.replace_at(lines, round * 100, "round #{round}\n"))
    end

    {_, 0} = git(["push", url, "main"], cd: local)
    assert %{packs: [_, _]} = state(server, "big")
    verify_packs!(server, "big", tmp_dir)
    assert state(server, "big").refs == %{"refs/heads/main" => rev!(local, "HEAD")}

    clone = Path.join(tmp_dir, "clone")
    {_, 0} = git(["clone", "-q", url, clone])
    assert rev!(clone, "HEAD") == rev!(local, "HEAD")
    assert {_, 0} = git(["fsck", "--full"], cd: clone)
  end

  test "max_objects limits a push, max_delta_depth a push and a stored pack", %{
    tmp_dir: tmp_dir,
  } do
    server = TestServer.start!()
    few_objects = TestServer.start!(store: server.store, max_objects: 2)
    no_deltas = TestServer.start!(store: server.store, max_delta_depth: 0)
    local = init!(Path.join(tmp_dir, "local"))
    lines = for i <- 1..3000, do: "line #{i} of a text file that changes a little each time\n"

    for round <- 1..4 do
      commit!(local, "big.txt", List.replace_at(lines, round * 100, "round #{round}\n"))
    end

    {output, 1} = git(["push", TestServer.url(few_objects, "big"), "main"], cd: local)
    assert output =~ "too many objects"
    {output, 1} = git(["push", TestServer.url(no_deltas, "big"), "main"], cd: local)
    assert output =~ "error: remote unpack failed: delta chain too deep (limit 0)\n"
    {_, 0} = git(["push", TestServer.url(server, "big"), "main"], cd: local)

    # A stored pack is read whatever its object count, but not past the delta depth.
    {_, 0} = git(["clone", "-q", TestServer.url(few_objects, "big"), Path.join(tmp_dir, "a")])

    log =
      capture_log(fn ->
        {output, 128} =
          git(["clone", "-q", TestServer.url(no_deltas, "big"), Path.join(tmp_dir, "b")])

        assert output =~ "delta chain too deep"
      end)

    assert log =~ ~r/repository big: pack [0-9a-f]{40}\.pack: delta chain too deep/
  end

  test "tags, an annotated tag and a branch delete", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    url = TestServer.url(server, "tags")
    head = commit!(local, "a", "a\n")
    {_, 0} = git(["tag", "light"], cd: local)
    {_, 0} = git(["tag", "-a", "v1", "-m", "version one"], cd: local)
    {_, 0} = git(["branch", "topic"], cd: local)
    {_, 0} = git(["push", url, "main", "topic", "--tags"], cd: local)

    tag = rev!(local, "refs/tags/v1")

    assert state(server, "tags").refs == %{
             "refs/heads/main" => head,
             "refs/heads/topic" => head,
             "refs/tags/light" => head,
             "refs/tags/v1" => tag,
           }

    {output, 0} = git(["push", url, ":topic"], cd: local)
    assert output =~ "[deleted]"
    refute Map.has_key?(state(server, "tags").refs, "refs/heads/topic")
  end

  test "a push over 1 MB, which git sends after a probe", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "random.bin", :crypto.strong_rand_bytes(3_000_000))

    {_, 0} = git(["push", TestServer.url(server, "large"), "main"], cd: local)
    assert state(server, "large").refs == %{"refs/heads/main" => head}
    verify_packs!(server, "large", tmp_dir)
  end

  test "a first push from a master checkout moves HEAD there", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"), "master")
    commit!(local, "a", "a\n")
    {_, 0} = git(["push", TestServer.url(server, "old"), "master"], cd: local)
    assert state(server, "old").head == "refs/heads/master"
    {output, 0} = git(["ls-remote", "--symref", TestServer.url(server, "old"), "HEAD"])
    assert output =~ "ref: refs/heads/master\tHEAD"
  end

  test "a non-fast-forward is refused, and a forced one lands", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    url = TestServer.url(server, "ff")
    commit!(local, "a", "1\n")
    {_, 0} = git(["push", url, "main"], cd: local)
    {_, 0} = git(["commit", "-q", "--amend", "-m", "rewritten"], cd: local)

    {output, 1} = git(["push", url, "main"], cd: local)
    assert output =~ "[rejected]"

    {_, 0} = git(["push", "--force", url, "main"], cd: local)
    assert state(server, "ff").refs["refs/heads/main"] == rev!(local, "HEAD")
  end

  test "git push --atomic of two new branches lands both", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "a", "a\n")
    {_, 0} = git(["branch", "one"], cd: local)
    {_, 0} = git(["branch", "two"], cd: local)
    {_, 0} = git(["push", "--atomic", TestServer.url(server, "atomic"), "one", "two"], cd: local)

    assert state(server, "atomic").refs == %{
             "refs/heads/one" => head,
             "refs/heads/two" => head,
           }
  end

  test "two pushes to one branch from one base: exactly one wins", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    base = init!(Path.join(tmp_dir, "base"))
    commit!(base, "a", "base\n")
    url = TestServer.url(server, "race")
    {_, 0} = git(["push", url, "main"], cd: base)

    clones =
      for name <- ["x", "y"] do
        clone = clone!(base, url, Path.join(tmp_dir, name))
        {name, clone, commit!(clone, "a", "#{name}\n")}
      end

    results =
      clones
      |> Enum.map(fn {_, clone, head} ->
        Task.async(fn -> {head, git(["push", "origin", "main"], cd: clone)} end)
      end)
      |> Task.await_many(60_000)

    assert [{winner, {_, 0}}] = Enum.filter(results, &match?({_, {_, 0}}, &1))
    assert [{_, {output, 1}}] = Enum.reject(results, &match?({_, {_, 0}}, &1))
    assert output =~ "fetch first"
    assert state(server, "race").refs["refs/heads/main"] == winner
  end

  test "ten concurrent pushes to ten branches all land", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "ten")

    heads =
      for i <- 1..10 do
        local = init!(Path.join(tmp_dir, "local#{i}"))
        {"refs/heads/b#{i}", local, commit!(local, "f", "#{i}\n")}
      end

    heads
    |> Enum.map(fn {ref, local, _head} ->
      Task.async(fn -> git(["push", url, "main:#{ref}"], cd: local) end)
    end)
    |> Task.await_many(60_000)
    |> Enum.each(fn result -> assert {_, 0} = result end)

    state = state(server, "ten")
    assert state.refs == Map.new(heads, fn {ref, _, head} -> {ref, head} end)
    assert length(state.packs) == 10
  end
end
