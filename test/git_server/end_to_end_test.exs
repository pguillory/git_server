defmodule GitServer.EndToEndTest do
  # Whole workflows with the real git client, starting from an empty repository and
  # with nothing seeded: everything in the bucket got there by `git push`.
  use ExUnit.Case, async: true
  import GitServer.TestGit
  alias GitServer.TestServer

  @moduletag :tmp_dir

  @race_ms 20_000
  @min_rounds 3

  defmodule Host do
    # A host application, mounting the Plug the way the README says.
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    forward("/git", to: GitServer.Plug, init_opts: [config: {__MODULE__, :config, []}])

    def config do
      [store: :persistent_term.get(__MODULE__), authorize: &authorize/1]
    end

    defp authorize(%{repo: "team/notes", credentials: {"user", "secret"}}) do
      :ok
    end

    defp authorize(%{repo: "team/notes"}) do
      :unauthorized
    end

    defp authorize(_request) do
      :forbidden
    end
  end

  defp commit!(dir, file, content, message) do
    File.write!(Path.join(dir, file), content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", message], cd: dir)
    head!(dir)
  end

  defp head!(dir) do
    {id, 0} = git(["rev-parse", "HEAD"], cd: dir)
    String.trim(id)
  end

  test "two people share a repository", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "team/shared")
    a = Path.join(tmp_dir, "a")
    b = Path.join(tmp_dir, "b")

    {output, 0} = git(["clone", url, a])
    assert output =~ "empty repository"
    {output, 0} = git(["clone", url, b])
    assert output =~ "empty repository"

    first = commit!(a, "README", "hello\n", "first")
    {_, 0} = git(["push", "-u", "origin", "main"], cd: a)

    {_, 0} = git(["pull", "origin", "main"], cd: b)
    assert head!(b) == first
    {_, 0} = git(["branch", "--set-upstream-to=origin/main", "main"], cd: b)

    second = commit!(b, "from-b", "b\n", "second")
    {_, 0} = git(["push"], cd: b)

    commit!(a, "from-a", "a\n", "third")
    {output, 1} = git(["push"], cd: a)
    assert output =~ "[rejected]"
    assert output =~ "fetch first"

    {_, 0} = git(["pull", "--rebase"], cd: a)
    {_, 0} = git(["push"], cd: a)
    {_, 0} = git(["pull"], cd: b)

    assert head!(a) == head!(b)
    assert {"#{head!(a)}\tHEAD\n#{head!(a)}\trefs/heads/main\n", 0} == git(["ls-remote", url])
    {parent, 0} = git(["rev-parse", "HEAD~1"], cd: a)
    assert String.trim(parent) == second

    for dir <- [a, b] do
      assert File.read!(Path.join(dir, "from-a")) == "a\n"
      assert File.read!(Path.join(dir, "from-b")) == "b\n"
      {_, 0} = git(["fsck", "--full"], cd: dir)
    end
  end

  test "mounted under a path in a host's router", %{tmp_dir: tmp_dir} do
    :persistent_term.put(Host, GitServer.TestStore.fresh())

    pid =
      start_supervised!(
        {Bandit, plug: Host, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    url = "http://user:secret@127.0.0.1:#{port}/git/team/notes.git"
    a = Path.join(tmp_dir, "a")
    b = Path.join(tmp_dir, "b")

    {_, 0} = git(["clone", "-q", url, a])
    commit!(a, "README", "hello\n", "first")
    {_, 0} = git(["push", "-q", "origin", "main"], cd: a)
    {_, 0} = git(["clone", "-q", url, b])
    assert head!(a) == head!(b)

    {output, status} = git(["ls-remote", "http://user:wrong@127.0.0.1:#{port}/git/team/notes"])
    assert status != 0
    assert output =~ "Authentication failed"

    {output, status} = git(["ls-remote", "http://user:secret@127.0.0.1:#{port}/git/other"])
    assert status != 0
    assert output =~ "403"
  end

  # One loop pushes while another clones. Every clone must be whole, and at a commit
  # that was pushed and at least as new as the last push finished before it started.
  # The history is linear and clones run one after another, so a later clone can never
  # see an earlier commit. Each loop runs a minimum number of rounds even if a slow
  # bucket uses up the time.
  @tag :slow
  @tag timeout: 300_000
  test "clones racing pushes are always whole and current", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, "racing")
    local = Path.join(tmp_dir, "local")
    {_, 0} = git(["init", "-q", "-b", "main", local])
    first = commit!(local, "count", "0\n", "commit 0")
    {_, 0} = git(["push", url, "main"], cd: local)
    deadline = System.monotonic_time(:millisecond) + @race_ms
    finished = :counters.new(1, [])

    pusher = Task.async(fn -> push_until(deadline, finished, local, url, [first]) end)
    cloner = Task.async(fn -> clone_until(deadline, finished, tmp_dir, url, []) end)
    [pushed, cloned] = Task.await_many([pusher, cloner], 280_000)

    positions = pushed |> Enum.with_index() |> Map.new()
    seen = Enum.map(cloned, fn {_floor, head} -> Map.fetch!(positions, head) end)
    assert seen == Enum.sort(seen)

    for {{floor, _head}, position} <- Enum.zip(cloned, seen) do
      assert position >= floor
    end

    {_floor, last} = clone!(finished, tmp_dir, url, "last")
    assert last == List.last(pushed)
  end

  defp push_until(deadline, finished, local, url, pushed) do
    count = length(pushed)

    if count < @min_rounds or System.monotonic_time(:millisecond) < deadline do
      head = commit!(local, "count", "#{count}\n", "commit #{count}")
      {_, 0} = git(["push", url, "main"], cd: local)
      :counters.add(finished, 1, 1)
      push_until(deadline, finished, local, url, [head | pushed])
    else
      Enum.reverse(pushed)
    end
  end

  defp clone_until(deadline, finished, tmp_dir, url, cloned) do
    count = length(cloned)

    if count < @min_rounds or System.monotonic_time(:millisecond) < deadline do
      clone = clone!(finished, tmp_dir, url, count)
      clone_until(deadline, finished, tmp_dir, url, [clone | cloned])
    else
      Enum.reverse(cloned)
    end
  end

  # A checked clone: the number of pushes finished before it started, and its head.
  defp clone!(finished, tmp_dir, url, name) do
    floor = :counters.get(finished, 1)
    dir = Path.join(tmp_dir, "clone-#{name}")
    {_, 0} = git(["clone", "-q", url, dir])
    {_, 0} = git(["fsck", "--full"], cd: dir)
    head = head!(dir)
    File.rm_rf!(dir)
    {floor, head}
  end
end
