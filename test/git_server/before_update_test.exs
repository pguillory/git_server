defmodule GitServer.BeforeUpdateTest do
  # The host's push check, with the real git client.
  use ExUnit.Case, async: true
  import GitServer.TestGit
  alias GitServer.Push
  alias GitServer.Repository
  alias GitServer.State
  alias GitServer.Store
  alias GitServer.TestServer

  @moduletag :tmp_dir

  defp state(server, repo) do
    {:ok, state, _etag} = Repository.read_state(server.store, repo)
    state
  end

  defp init!(dir) do
    {_, 0} = git(["init", "-q", "-b", "main", dir])
    dir
  end

  defp commit!(dir, file, content) do
    path = Path.join(dir, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", "change"], cd: dir)
    rev!(dir, "HEAD")
  end

  defp rev!(dir, rev) do
    {id, 0} = git(["rev-parse", rev], cd: dir)
    String.trim(id)
  end

  # Runs `fun` on the push in the hook's process and sends its result to the test.
  defp observe(fun) do
    test = self()

    fn push ->
      send(test, {:called, push.refs, push.updates, fun.(push)})
      :ok
    end
  end

  defp start!(before_update, opts \\ []) do
    TestServer.start!([before_update: before_update] ++ opts)
  end

  test "an approved push lands, and the check saw the update", %{tmp_dir: tmp_dir} do
    server = start!(observe(fn _ -> nil end))
    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "README", "hello\n")

    {_, 0} = git(["push", TestServer.url(server, "r"), "main"], cd: local)
    assert_received {:called, refs, [%{ref: "refs/heads/main", old: nil, new: ^head}], nil}
    assert refs == %{}
    assert state(server, "r").refs == %{"refs/heads/main" => head}
  end

  test "a rejected push shows the host's message and changes nothing", %{tmp_dir: tmp_dir} do
    long = String.duplicate("x", 70_000)
    server = start!(fn _push -> {:reject, "first line\nsecond line\n#{long}"} end)
    local = init!(Path.join(tmp_dir, "local"))
    commit!(local, "README", "hello\n")
    url = TestServer.url(server, "r")

    {output, 1} = git(["push", url, "main"], cd: local)
    # git pads each `remote:` line with spaces, to cover any progress text.
    output = String.replace(output, ~r/ +\n/, "\n")
    assert output =~ "remote: first line\nremote: second line\nremote: #{long}\n"
    assert output =~ "! [remote rejected] main -> main (declined)"
    assert Repository.read_state(server.store, "r") == {:ok, State.new(), :absent}
    assert Store.list(server.store, GitServer.RepoName.key_prefix("r")) == {:ok, []}
    assert git(["ls-remote", url]) == {"", 0}
  end

  test "a check reads files at the pushed tip and the old one", %{tmp_dir: tmp_dir} do
    test = self()

    check = fn push ->
      [update] = push.updates
      {:ok, rules} = Push.read_file(push, update.new, "rules/a.txt")
      {:ok, files} = Push.list_files(push, update.new)
      old = if update.old, do: Push.read_file(push, update.old, "rules/a.txt")
      send(test, {:read, Enum.map(files, & &1.path), old})

      if rules =~ "bad",
        do: {:reject, "rules/a.txt: bad rule"},
        else: :ok
    end

    server = start!(check)
    local = init!(Path.join(tmp_dir, "local"))
    url = TestServer.url(server, "r")
    commit!(local, "rules/a.txt", "good\n")
    commit!(local, "top.txt", "top\n")

    {_, 0} = git(["push", url, "main"], cd: local)
    assert_received {:read, ["rules/a.txt", "top.txt"], nil}
    good = rev!(local, "HEAD")

    commit!(local, "rules/a.txt", "bad\n")
    {output, 1} = git(["push", url, "main"], cd: local)
    assert output =~ "remote: rules/a.txt: bad rule"
    assert output =~ "(declined)"
    assert_received {:read, _files, {:ok, "good\n"}}
    assert state(server, "r").refs == %{"refs/heads/main" => good}

    clone = Path.join(tmp_dir, "clone")
    {_, 0} = git(["clone", "-q", url, clone])
    assert File.read!(Path.join(clone, "rules/a.txt")) == "good\n"
  end

  test "file types, missing paths, tags and trees", %{tmp_dir: tmp_dir} do
    server = start!(observe(&read_cases/1))
    local = init!(Path.join(tmp_dir, "local"))
    commit!(local, "dir/file", "content\n")
    File.ln_s!("dir/file", Path.join(local, "link"))
    File.write!(Path.join(local, "run"), "#!/bin/sh\n")
    File.chmod!(Path.join(local, "run"), 0o755)
    sub = String.duplicate("ab", 20)
    {_, 0} = git(["add", "-A"], cd: local)
    {_, 0} = git(["update-index", "--add", "--cacheinfo", "160000,#{sub},sub"], cd: local)
    {_, 0} = git(["commit", "-q", "-m", "types"], cd: local)
    {_, 0} = git(["tag", "-a", "v1", "-m", "one"], cd: local)

    {_, 0} = git(["push", TestServer.url(server, "r"), "refs/tags/v1"], cd: local)
    assert_received {:called, _refs, [%{ref: "refs/tags/v1"}], results}

    assert results.files == [
             %{path: "dir/file", type: :file},
             %{path: "link", type: :symlink},
             %{path: "run", type: :executable},
             %{path: "sub", type: :submodule, id: sub},
           ]

    assert results.reads == [
             {:ok, "content\n"},
             {:error, "link is a symlink"},
             {:error, "link is a symlink"},
             {:ok, "#!/bin/sh\n"},
             :error,
             :error,
             :error,
             :error,
             :error,
           ]

    assert {:error, _} = results.blob
  end

  defp read_cases(push) do
    [%{new: tag}] = push.updates
    {:ok, files} = Push.list_files(push, tag)
    {:ok, [%{id: dir_file}]} = Push.list_files(push, tag) |> only("dir/file")

    %{
      files:
        Enum.map(files, fn
          %{type: :submodule} = file -> file
          file -> Map.delete(file, :id)
        end),
      reads:
        Enum.map(
          [
            "dir/file",
            "link",
            "link/x",
            "run",
            "sub",
            "dir",
            "missing",
            "dir/../dir/file",
            "/dir/file",
          ],
          &Push.read_file(push, tag, &1)
        ),
      blob: Push.list_files(push, dir_file),
    }
  end

  defp only({:ok, files}, path) do
    {:ok, Enum.filter(files, &(&1.path == path))}
  end

  test "a multi-ref push is seen whole and refused whole", %{tmp_dir: tmp_dir} do
    server =
      start!(fn push ->
        if Enum.any?(push.updates, &(&1.ref == "refs/heads/bad")),
          do: {:reject, "no bad branch"},
          else: :ok
      end)

    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "README", "hello\n")
    {_, 0} = git(["branch", "topic"], cd: local)
    {_, 0} = git(["branch", "bad"], cd: local)
    url = TestServer.url(server, "r")

    {output, 1} = git(["push", url, "main", "topic", "bad"], cd: local)
    assert output =~ "main -> main (declined)"
    assert output =~ "topic -> topic (declined)"
    assert output =~ "bad -> bad (declined)"
    assert state(server, "r").refs == %{}

    {_, 0} = git(["push", url, "main", "topic"], cd: local)
    assert state(server, "r").refs == %{"refs/heads/main" => head, "refs/heads/topic" => head}
  end

  test "a delete is seen as new: nil", %{tmp_dir: tmp_dir} do
    server =
      start!(fn push ->
        if Enum.any?(push.updates, &(&1.ref == "refs/heads/keep" and &1.new == nil)),
          do: {:reject, "keep stays"},
          else: :ok
      end)

    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "README", "hello\n")
    {_, 0} = git(["branch", "keep"], cd: local)
    {_, 0} = git(["branch", "gone"], cd: local)
    url = TestServer.url(server, "r")
    {_, 0} = git(["push", url, "main", "keep", "gone"], cd: local)

    {_, 0} = git(["push", url, ":gone"], cd: local)
    {output, 1} = git(["push", url, ":keep"], cd: local)
    assert output =~ "remote: keep stays"
    assert state(server, "r").refs == %{"refs/heads/main" => head, "refs/heads/keep" => head}
  end

  test "a check that approved before a lost race is asked again", %{tmp_dir: tmp_dir} do
    # At most one branch: approves our push against the empty repository, then sees
    # the other push's branch on the retry.
    test = self()

    check = fn push ->
      send(test, {:refs, Map.keys(push.refs)})
      after_push = Map.keys(push.refs) ++ Enum.map(push.updates, & &1.ref)
      if length(Enum.uniq(after_push)) > 1, do: {:reject, "one branch only"}, else: :ok
    end

    other = init!(Path.join(tmp_dir, "other"))
    other_head = commit!(other, "b", "other\n")
    {:ok, url} = Agent.start_link(fn -> nil end)
    store = GitServer.TestStore.fresh()

    racing =
      GitServer.RacingStore.wrap(store, fn ->
        {_, 0} = git(["push", Agent.get(url, & &1), "main:other"], cd: other)
      end)

    server = %{start!(check, store: racing) | store: store}
    Agent.update(url, fn _ -> TestServer.url(server, "r") end)
    local = init!(Path.join(tmp_dir, "local"))
    commit!(local, "a", "local\n")

    {output, 1} = git(["push", TestServer.url(server, "r"), "main"], cd: local)
    assert output =~ "remote: one branch only"
    assert output =~ "main -> main (declined)"
    assert state(server, "r").refs == %{"refs/heads/other" => other_head}
    # Ours against the empty repository, the other push's, then ours again.
    assert_received {:refs, []}
    assert_received {:refs, []}
    assert_received {:refs, ["refs/heads/other"]}
  end

  test "a check asked again after a lost race can approve, and the push lands",
       %{tmp_dir: tmp_dir} do
    test = self()

    check = fn push ->
      send(test, {:refs, Map.keys(push.refs)})
      :ok
    end

    other = init!(Path.join(tmp_dir, "other"))
    other_head = commit!(other, "b", "other\n")
    {:ok, url} = Agent.start_link(fn -> nil end)
    store = GitServer.TestStore.fresh()

    racing =
      GitServer.RacingStore.wrap(store, fn ->
        {_, 0} = git(["push", Agent.get(url, & &1), "main:other"], cd: other)
      end)

    server = %{start!(check, store: racing) | store: store}
    Agent.update(url, fn _ -> TestServer.url(server, "r") end)
    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "a", "local\n")

    {_, 0} = git(["push", TestServer.url(server, "r"), "main"], cd: local)

    assert state(server, "r").refs == %{
             "refs/heads/other" => other_head,
             "refs/heads/main" => head,
           }

    assert_received {:refs, []}
    assert_received {:refs, []}
    assert_received {:refs, ["refs/heads/other"]}
  end

  test "hostile trees stop at the budget", %{tmp_dir: tmp_dir} do
    local = init!(Path.join(tmp_dir, "local"))

    tree = fn entries ->
      tree!(local, tmp_dir, Enum.map(entries, &Tuple.insert_at(&1, 0, "40000")))
    end

    # 2^40 paths from 41 trees, every one a directory.
    doubling = Enum.reduce(1..40, tree.([]), fn _, t -> tree.([{"a", t}, {"b", t}]) end)

    # 1,000 files under a chain of 100 directories with 200-byte names: about 20 MB of
    # paths from 101 trees and one blob.
    blob = blob!(local, tmp_dir, "x")
    files = tree!(local, tmp_dir, for(i <- 1..1000, do: {"100644", "f#{i}", blob}))

    deep =
      Enum.reduce(1..100, files, &tree.([{String.duplicate("d", 199) <> "#{rem(&1, 10)}", &2}]))

    server =
      start!(
        observe(fn push ->
          # Small budgets, so each tree trips its own limit after bounded work. The
          # defaults are the same checks with bigger numbers.
          Enum.map(
            push.updates,
            &Push.list_files(push, &1.new, max_entries: 1_000, max_path_bytes: 5_000_000)
          )
        end)
      )

    for {tree, name} <- [{doubling, "doubling"}, {deep, "deep"}] do
      {commit, 0} = git(["commit-tree", tree, "-m", name], cd: local)
      {_, 0} = git(["update-ref", "refs/heads/#{name}", String.trim(commit)], cd: local)
    end

    {_, 0} = git(["push", TestServer.url(server, "r"), "doubling", "deep"], cd: local)
    assert_received {:called, _refs, _updates, results}
    assert results == [{:error, "too many files"}, {:error, "paths too long"}]
  end

  test "trees with unsafe names can't be read", %{tmp_dir: tmp_dir} do
    local = init!(Path.join(tmp_dir, "local"))
    blob = blob!(local, tmp_dir, "x")

    trees =
      for names <- [
            ["a/b"],
            [".git"],
            [".GIT"],
            [".git."],
            [".."],
            ["same", "same"],
            ["Same", "same"],
          ] do
        tree = tree!(local, tmp_dir, Enum.map(names, &{"100644", &1, blob}))
        {commit, 0} = git(["commit-tree", tree, "-m", "x"], cd: local)
        String.trim(commit)
      end

    for {commit, i} <- Enum.with_index(trees) do
      {_, 0} = git(["update-ref", "refs/heads/t#{i}", commit], cd: local)
    end

    server =
      start!(
        observe(fn push ->
          for update <- push.updates,
              do: {Push.list_files(push, update.new), Push.read_file(push, update.new, "same")}
        end)
      )

    {_, 0} = git(["push", TestServer.url(server, "r"), "refs/heads/*"], cd: local)
    assert_received {:called, _refs, _updates, results}
    assert length(results) == 7

    for {listed, read} <- results do
      assert {:error, reason} = listed
      assert reason =~ "unsafe entry name"
      assert {:error, ^reason} = read
    end
  end

  # Objects written as given, unchecked, so a test can build what git wouldn't.
  defp tree!(dir, tmp_dir, entries) do
    content =
      Enum.map(entries, fn {mode, name, hex} ->
        {:ok, id} = GitServer.ObjectId.from_hex(hex)
        [mode, " ", name, 0, id]
      end)

    write_object!(dir, tmp_dir, "tree", content)
  end

  defp blob!(dir, tmp_dir, content) do
    write_object!(dir, tmp_dir, "blob", content)
  end

  defp write_object!(dir, tmp_dir, type, content) do
    path = Path.join(tmp_dir, "object")
    File.write!(path, content)
    {id, 0} = git(["hash-object", "-t", type, "-w", "--literally", path], cd: dir)
    String.trim(id)
  end
end
