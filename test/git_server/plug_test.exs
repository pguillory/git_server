defmodule GitServer.PlugTest do
  use ExUnit.Case, async: true
  import GitServer.TestGit
  alias GitServer.{Repository, State, TestServer}

  @commit "1111111111111111111111111111111111111111"
  @tag_id "2222222222222222222222222222222222222222"

  test "ls-remote of an empty repository" do
    server = TestServer.start!()
    assert git(["ls-remote", TestServer.url(server, "empty")]) == {"", 0}
    assert git(["ls-remote", TestServer.url(server, "a/b/empty.git")]) == {"", 0}
  end

  @tag :tmp_dir
  test "cloning an empty repository", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    {output, 0} = git(["clone", TestServer.url(server, "empty"), "clone"], cd: tmp_dir)
    assert output =~ "You appear to have cloned an empty repository"

    assert git(["symbolic-ref", "HEAD"], cd: Path.join(tmp_dir, "clone")) ==
             {"refs/heads/main\n", 0}
  end

  test "ls-remote lists refs with HEAD as a symref" do
    server = TestServer.start!()

    state = %State{
      head: "refs/heads/main",
      refs: %{"refs/heads/main" => @commit, "refs/tags/v1" => @tag_id},
    }

    {:ok, _} = Repository.put_state(server.store, "alice/notes", state, :absent)

    assert git(["ls-remote", "--symref", TestServer.url(server, "alice/notes.git")]) ==
             {"""
              ref: refs/heads/main\tHEAD
              #{@commit}\tHEAD
              #{@commit}\trefs/heads/main
              #{@tag_id}\trefs/tags/v1
              """, 0}

    assert git(["ls-remote", "--heads", TestServer.url(server, "alice/notes")]) ==
             {"#{@commit}\trefs/heads/main\n", 0}
  end

  test "a wrong password is refused with a 401" do
    server = TestServer.start!()
    {output, status} = git(["ls-remote", TestServer.url(server, "repo", "user", "wrong")])
    assert status == 128
    assert output =~ "Authentication failed"
  end

  @tag :tmp_dir
  test "a forbidden repository is refused with a 403, and authorize sees the request", %{
    tmp_dir: tmp_dir,
  } do
    test = self()

    # Git sends credentials only after a 401.
    authorize = fn request ->
      send(test, {:authorize, Map.delete(request, :conn)})
      if request.credentials, do: :forbidden, else: :unauthorized
    end

    server = TestServer.start!(authorize: authorize)
    {output, status} = git(["ls-remote", TestServer.url(server, "team/repo.git")])
    assert status == 128
    assert output =~ "403"
    assert_received {:authorize, %{repo: "team/repo", access: :read, credentials: nil}}

    assert_received {:authorize,
                     %{repo: "team/repo", access: :read, credentials: {"user", "secret"}}}

    {_, 0} = git(["init", "-q", tmp_dir])
    {_, 0} = git(["commit", "-q", "--allow-empty", "-m", "first"], cd: tmp_dir)
    {output, 128} = git(["push", TestServer.url(server, "team/repo"), "HEAD"], cd: tmp_dir)
    assert output =~ "403"
    assert_received {:authorize, %{repo: "team/repo", access: :write}}
  end

  test "protocol v0 fetching is refused with a message" do
    server = TestServer.start!()

    {output, status} =
      git(["-c", "protocol.version=0", "ls-remote", TestServer.url(server, "repo")])

    assert status == 128
    assert output =~ "needs Git protocol version 2"
  end

  test "config resolved on each request" do
    store = GitServer.TestStore.fresh()
    test = self()

    config = fn ->
      send(test, :resolved)
      [store: store, authorize: fn _ -> :ok end]
    end

    server = TestServer.start!(config: config)
    assert git(["ls-remote", server.url <> "/repo"]) == {"", 0}
    # info/refs, then the ls-refs POST.
    assert_received :resolved
    assert_received :resolved
  end
end
