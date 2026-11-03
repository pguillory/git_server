defmodule GitServer.AfterUpdateTest do
  # The host's after_update function, with the real git client.
  use ExUnit.Case, async: true
  import GitServer.TestGit
  alias GitServer.TestServer

  @moduletag :tmp_dir

  defp init!(dir) do
    {_, 0} = git(["init", "-q", "-b", "main", dir])
    dir
  end

  defp commit!(dir, file, content) do
    File.write!(Path.join(dir, file), content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", "change"], cd: dir)
    {id, 0} = git(["rev-parse", "HEAD"], cd: dir)
    String.trim(id)
  end

  defp observing(opts \\ []) do
    test = self()

    after_update = fn push ->
      send(test, {:landed, push.repo, push.updates, {push.conn.method, push.conn.status}})
    end

    TestServer.start!([after_update: after_update] ++ opts)
  end

  test "called once after a push lands, with what landed", %{tmp_dir: tmp_dir} do
    server = observing()
    local = init!(Path.join(tmp_dir, "local"))
    first = commit!(local, "a", "a\n")
    url = TestServer.url(server, "team/r")

    {_, 0} = git(["push", url, "main", "main:other"], cd: local)

    assert_receive {:landed, "team/r", updates, {"POST", 200}}

    assert Enum.sort_by(updates, & &1.ref) == [
             %{ref: "refs/heads/main", old: nil, new: first},
             %{ref: "refs/heads/other", old: nil, new: first},
           ]

    second = commit!(local, "b", "b\n")
    {_, 0} = git(["push", url, "main", ":other"], cd: local)

    assert_receive {:landed, "team/r",
                    [
                      %{ref: "refs/heads/main", old: ^first, new: ^second},
                      %{ref: "refs/heads/other", old: ^first, new: nil},
                    ], {"POST", 200}}

    # Without --atomic, only the refs that landed: refs/heads/main/sub can't sit
    # beside refs/heads/main, which the server refuses.
    third = commit!(local, "c", "c\n")
    {output, 1} = git(["push", url, "main", "main:refs/heads/main/sub"], cd: local)
    assert output =~ "main -> main/sub (ref name conflicts with an existing ref)"

    assert_receive {:landed, "team/r", [%{ref: "refs/heads/main", old: ^second, new: ^third}], _}

    refute_received {:landed, _, _, _}
  end

  test "not called for a declined or refused push", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    local = init!(Path.join(tmp_dir, "local"))
    commit!(local, "a", "a\n")
    declining = observing(store: store, before_update: fn _ -> {:reject, "no"} end)

    TestServer.await_post(declining, fn ->
      {_, 1} = git(["push", TestServer.url(declining, "r"), "main"], cd: local)
    end)

    refute_received {:landed, _, _, _}

    # A push the server refuses: a branch that names a tag object.
    {_, 0} = git(["tag", "-a", "v1", "-m", "v1"], cd: local)
    server = observing(store: store)

    TestServer.await_post(server, fn ->
      {output, 1} = git(["push", TestServer.url(server, "r"), "v1:refs/heads/v1"], cd: local)
      assert output =~ "(not a commit)"
    end)

    refute_received {:landed, _, _, _}
  end
end
