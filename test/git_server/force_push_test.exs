defmodule GitServer.ForcePushTest do
  # Rewriting history with the real git client: forced pushes, leases, deleted
  # branches and moved tags, and what clones see afterwards.
  use ExUnit.Case, async: true
  import GitServer.TestGit
  alias GitServer.RacingStore
  alias GitServer.Repository
  alias GitServer.Store
  alias GitServer.TestServer

  @moduletag :tmp_dir

  @race_rounds 6

  defp state(server, repo) do
    {:ok, state, _etag} = Repository.read_state(server.store, repo)
    state
  end

  defp init!(dir) do
    {_, 0} = git(["init", "-q", "-b", "main", dir])
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

  # A fresh clone, checked with fsck, then removed. Returns its refs.
  defp clone_refs!(url, tmp_dir) do
    dir = Path.join(tmp_dir, "clone-#{System.unique_integer([:positive])}")
    {_, 0} = git(["clone", "-q", url, dir])
    {_, 0} = git(["fsck", "--full", "--no-dangling"], cd: dir)
    {output, 0} = git(["for-each-ref", "--format=%(refname) %(objectname)"], cd: dir)
    File.rm_rf!(dir)

    for line <- String.split(output, "\n", trim: true),
        [ref, id] = String.split(line, " "),
        not String.starts_with?(ref, "refs/remotes/origin/HEAD"),
        into: %{},
        do: {ref, id}
  end

  # The object ids in every pack the state lists, read with git.
  defp packed_ids(server, repo, tmp_dir) do
    dir = Path.join(tmp_dir, "packs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Enum.flat_map(state(server, repo).packs, fn name ->
      idx = Path.join(dir, "#{name}.idx")
      pack = Path.join(dir, "#{name}.pack")
      {:ok, _} = Store.get_file(server.store, Repository.pack_key(repo, name), pack)
      {:ok, _} = Store.get_file(server.store, Repository.idx_key(repo, name), idx)
      {output, 0} = git(["verify-pack", "-v", idx])

      for line <- String.split(output, "\n"),
          [id | _] <- [String.split(line)],
          id =~ ~r/\A[0-9a-f]{40}\z/,
          do: id
    end)
  end

  test "a forced push overwrites someone else's change, and they pull", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "team")
    seed = init!(Path.join(tmp_dir, "seed"))
    base = commit!(seed, "README", "hello\n", "base")
    {_, 0} = git(["push", "-q", url, "main"], cd: seed)
    a = Path.join(tmp_dir, "a")
    b = Path.join(tmp_dir, "b")
    {_, 0} = git(["clone", "-q", url, a])
    {_, 0} = git(["clone", "-q", url, b])

    theirs = commit!(b, "from-b", "b\n", "b's change")
    {_, 0} = git(["push", "-q"], cd: b)

    mine = commit!(a, "from-a", "a\n", "a's change in a hurry")
    {output, 1} = git(["push"], cd: a)
    assert output =~ "[rejected]"
    {output, 0} = git(["push", "--force"], cd: a)
    assert output =~ "#{String.slice(theirs, 0, 7)}...#{String.slice(mine, 0, 7)}"
    assert output =~ "main -> main (forced update)"
    assert state(server, "team").refs == %{"refs/heads/main" => mine}

    {output, 0} = git(["pull", "--no-rebase"], cd: b)
    assert output =~ "(forced update)"
    assert rev!(b, "HEAD^1") == theirs
    assert rev!(b, "HEAD^2") == mine
    assert rev!(b, "HEAD^2~") == base
    assert File.read!(Path.join(b, "from-b")) == "b\n"
    assert File.read!(Path.join(b, "from-a")) == "a\n"
    {_, 0} = git(["push", "-q"], cd: b)

    assert clone_refs!(url, tmp_dir) == %{
             "refs/heads/main" => rev!(b, "HEAD"),
             "refs/remotes/origin/main" => rev!(b, "HEAD"),
           }
  end

  test "--force-with-lease lands when the remote hasn't moved and not when it has",
       %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "lease")
    seed = init!(Path.join(tmp_dir, "seed"))
    commit!(seed, "f", "0\n")
    {_, 0} = git(["push", "-q", url, "main"], cd: seed)
    a = Path.join(tmp_dir, "a")
    b = Path.join(tmp_dir, "b")
    {_, 0} = git(["clone", "-q", url, a])
    {_, 0} = git(["clone", "-q", url, b])

    # Unmoved: a rewrites its tip and the lease holds.
    {_, 0} = git(["commit", "-q", "--amend", "-m", "rewritten"], cd: a)
    {output, 0} = git(["push", "--force-with-lease"], cd: a)
    assert output =~ "(forced update)"
    rewritten = rev!(a, "HEAD")

    # Moved: b pushes on top, and a's lease, from before that, is refused.
    {_, 0} = git(["pull", "-q", "--rebase"], cd: b)
    moved = commit!(b, "g", "b\n")
    {_, 0} = git(["push", "-q"], cd: b)
    {_, 0} = git(["commit", "-q", "--amend", "-m", "rewritten again"], cd: a)
    {output, 1} = git(["push", "--force-with-lease"], cd: a)
    assert output =~ "[rejected]"
    assert output =~ "stale info"

    # An explicit lease at the old value is refused the same way.
    {output, 1} = git(["push", "--force-with-lease=main:#{rewritten}"], cd: a)
    assert output =~ "stale info"
    assert state(server, "lease").refs == %{"refs/heads/main" => moved}

    # After a fetch the lease names the current value, and holds.
    {_, 0} = git(["fetch", "-q"], cd: a)
    {_, 0} = git(["push", "-q", "--force-with-lease"], cd: a)
    assert state(server, "lease").refs == %{"refs/heads/main" => rev!(a, "HEAD")}
    assert clone_refs!(url, tmp_dir)["refs/heads/main"] == rev!(a, "HEAD")
  end

  # git checks a lease against the advertisement, so here the remote moves after
  # that, between the server's check of the push and its state write. The server
  # must decide the lease again on its retry, and refuse it.
  test "a lease that goes stale after the advertisement is refused by the server",
       %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    plain = TestServer.start!(store: store)
    local = init!(Path.join(tmp_dir, "local"))
    leased = commit!(local, "f", "0\n")
    other = commit!(local, "f", "1\n")
    refspecs = ["#{leased}:refs/heads/main", "#{other}:refs/heads/other"]
    {_, 0} = git(["push", "-q", TestServer.url(plain, "stale") | refspecs], cd: local)

    racing =
      RacingStore.wrap(store, fn ->
        {:ok, state, etag} = Repository.read_state(store, "stale")
        refs = Map.put(state.refs, "refs/heads/main", other)
        {:ok, _} = Repository.put_state(store, "stale", %{state | refs: refs}, etag)
      end)

    server = TestServer.start!(store: racing)
    {_, 0} = git(["checkout", "-q", "--detach", leased], cd: local)
    {_, 0} = git(["commit", "-q", "--amend", "-m", "rewritten"], cd: local)

    {output, 1} =
      git(
        [
          "push",
          "--force-with-lease=main:#{leased}",
          TestServer.url(server, "stale"),
          "HEAD:main",
        ],
        cd: local
      )

    assert output =~ "[rejected]        HEAD -> main (fetch first)"

    assert state(server, "stale").refs == %{
             "refs/heads/main" => other,
             "refs/heads/other" => other,
           }

    assert clone_refs!(TestServer.url(plain, "stale"), tmp_dir)["refs/heads/main"] == other
  end

  test "a remote branch is deleted, and later clones don't have it", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "branches")
    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "f", "0\n")
    topic = commit!(local, "f", "topic\n")
    {_, 0} = git(["push", "-q", url, "HEAD~:refs/heads/main", "HEAD:refs/heads/topic"], cd: local)

    assert Map.keys(clone_refs!(url, tmp_dir)) |> Enum.sort() == [
             "refs/heads/main",
             "refs/remotes/origin/main",
             "refs/remotes/origin/topic",
           ]

    {output, 0} = git(["push", "--delete", url, "topic"], cd: local)
    assert output =~ "- [deleted]         topic"
    assert state(server, "branches").refs == %{"refs/heads/main" => head}
    refute topic in Map.values(clone_refs!(url, tmp_dir))

    {output, status} = git(["push", "--delete", url, "topic"], cd: local)
    assert status != 0
    assert output =~ "remote ref does not exist"
  end

  test "tags, lightweight and annotated, pushed, force-moved and deleted",
       %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "tags")
    local = init!(Path.join(tmp_dir, "local"))
    first = commit!(local, "f", "0\n")
    {_, 0} = git(["tag", "light"], cd: local)
    {_, 0} = git(["tag", "-a", "v1", "-m", "version one"], cd: local)
    {_, 0} = git(["push", "-q", url, "main", "--tags"], cd: local)
    v1 = rev!(local, "refs/tags/v1")

    refs = clone_refs!(url, tmp_dir)
    assert refs["refs/tags/light"] == first
    assert refs["refs/tags/v1"] == v1

    # Moving a tag takes a force.
    second = commit!(local, "f", "1\n")
    {_, 0} = git(["tag", "-f", "light"], cd: local)
    {_, 0} = git(["tag", "-f", "-a", "v1", "-m", "version one, again"], cd: local)
    moved_v1 = rev!(local, "refs/tags/v1")
    {_, 0} = git(["push", "-q", url, "main"], cd: local)
    {output, 1} = git(["push", url, "--tags"], cd: local)
    assert output =~ "[rejected]"
    assert output =~ "already exists"
    {output, 0} = git(["push", "--force", url, "--tags"], cd: local)
    assert output =~ "(forced update)"

    refs = clone_refs!(url, tmp_dir)
    assert refs["refs/tags/light"] == second
    assert refs["refs/tags/v1"] == moved_v1
    {_, 0} = git(["cat-file", "-e", v1], cd: local)
    refute v1 == moved_v1

    # Deleting both.
    {output, 0} = git(["push", url, "--delete", "light", "v1"], cd: local)
    assert output =~ "- [deleted]         light"
    assert output =~ "- [deleted]         v1"
    assert state(server, "tags").refs == %{"refs/heads/main" => second}

    assert clone_refs!(url, tmp_dir) == %{
             "refs/heads/main" => second,
             "refs/remotes/origin/main" => second,
           }
  end

  test "history left behind by a forced push stays packed, can't be fetched, and breaks nothing",
       %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "orphans")
    local = init!(Path.join(tmp_dir, "local"))
    base = commit!(local, "f", "0\n")
    old = commit!(local, "secret", "leaked\n", "oops")
    {_, 0} = git(["push", "-q", url, "main"], cd: local)
    stale = Path.join(tmp_dir, "stale")
    {_, 0} = git(["clone", "-q", url, stale])
    {_, 0} = git(["reset", "-q", "--hard", base], cd: local)
    new = commit!(local, "f", "1\n", "redone")
    {_, 0} = git(["push", "-q", "--force", url, "main"], cd: local)

    assert old in packed_ids(server, "orphans", tmp_dir)
    assert clone_refs!(url, tmp_dir)["refs/heads/main"] == new

    clone = Path.join(tmp_dir, "clone")
    {_, 0} = git(["clone", "-q", url, clone])
    {_, status} = git(["cat-file", "-e", old], cd: clone)
    assert status != 0
    {output, status} = git(["fetch", "origin", old], cd: clone)
    assert status != 0
    assert output =~ "not our ref #{old}"

    # Building on the new history works, and so does a fetch into a clone from before
    # the forced push, which offers the old commit as a have.
    next = commit!(clone, "g", "2\n")
    {_, 0} = git(["push", "-q"], cd: clone)
    {output, 0} = git(["fetch", "origin"], cd: stale)
    assert output =~ "(forced update)"
    assert rev!(stale, "origin/main") == next
    {_, 0} = git(["fsck", "--full", "--no-dangling"], cd: stale)
    assert clone_refs!(url, tmp_dir)["refs/heads/main"] == next
  end

  # Each round, from the same tip, one person pushes a commit on top while another
  # force-pushes a rewrite of the tip. Either one push is refused and the other's
  # commit is the tip, or the ordinary push landed first and the forced one then
  # overwrote it. Never both refused, never a tip nobody pushed.
  @tag timeout: 300_000
  test "a forced push racing an ordinary push", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "race")
    seed = init!(Path.join(tmp_dir, "seed"))
    commit!(seed, "f", "0\n")
    {_, 0} = git(["push", "-q", url, "main"], cd: seed)
    plain = Path.join(tmp_dir, "plain")
    forced = Path.join(tmp_dir, "forced")
    {_, 0} = git(["clone", "-q", url, plain])
    {_, 0} = git(["clone", "-q", url, forced])

    for round <- 1..@race_rounds do
      for dir <- [plain, forced] do
        {_, 0} = git(["fetch", "-q"], cd: dir)
        {_, 0} = git(["reset", "-q", "--hard", "origin/main"], cd: dir)
      end

      tip = rev!(plain, "HEAD")
      on_top = commit!(plain, "f", "plain #{round}\n")
      {_, 0} = git(["commit", "-q", "--amend", "-m", "forced #{round}"], cd: forced)
      rewrite = rev!(forced, "HEAD")

      [plain_result, forced_result] =
        [
          Task.async(fn -> git(["push"], cd: plain) end),
          Task.async(fn -> git(["push", "--force"], cd: forced) end),
        ]
        |> Task.await_many(60_000)

      final = state(server, "race").refs["refs/heads/main"]

      case {plain_result, forced_result} do
        {{_, 0}, {output, 1}} ->
          assert final == on_top
          assert output =~ "[rejected]"

        {{output, 1}, {_, 0}} ->
          assert final == rewrite
          assert output =~ "[rejected]"

        {{_, 0}, {output, 0}} ->
          assert final == rewrite
          assert output =~ "#{String.slice(on_top, 0, 7)}..."
      end

      refute final == tip
      assert clone_refs!(url, tmp_dir)["refs/heads/main"] == final
    end
  end
end
