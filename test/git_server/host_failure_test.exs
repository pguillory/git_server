defmodule GitServer.HostFailureTest do
  # A host function (config, authorize, before_update, after_update) that raises,
  # throws, exits or returns something else: the request is refused (or, for
  # after_update, goes on), and the failure is logged by kind with nothing it carried,
  # since the host's functions see credentials, options and pushed content. Includes
  # the README's "When something goes wrong" rows for these failures.
  #
  # Not async: each test captures the log, which must hold only its own lines.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import GitServer.TestGit
  alias GitServer.Repository
  alias GitServer.TestServer

  @moduletag :tmp_dir

  @password "pw-7f3a9c-distinctive"

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

  defp refs(server, repo) do
    {:ok, state, _etag} = Repository.read_state(server.store, repo)
    state.refs
  end

  # Git sends credentials only after a 401, so each authorize answers that first.
  defp ls_remote(authorize) do
    server = TestServer.start!(authorize: authorize)
    url = TestServer.url(server, "repo", "user", @password)

    log =
      capture_log(fn ->
        {output, status} = git(["ls-remote", url])
        assert status == 128
        assert output =~ "500"
        refute output =~ @password
      end)

    refute log =~ @password
    refute log =~ Base.encode64("user:" <> @password)
    log
  end

  test "an authorize that raises logs no credentials and refuses the request" do
    # A host's authorize with no clause for these credentials.
    log =
      ls_remote(fn
        %{credentials: nil} -> :unauthorized
        %{credentials: {"someone-else", _}} -> :ok
      end)

    assert log =~ "the authorize function raised FunctionClauseError"
    assert log =~ "test/git_server/host_failure_test.exs"
    refute log =~ "someone-else"
  end

  test "an authorize that throws or exits logs no credentials and refuses the request" do
    log =
      ls_remote(fn
        %{credentials: nil} -> :unauthorized
        %{credentials: credentials} -> throw({:failed, credentials})
      end)

    assert log =~ "the authorize function threw"

    log =
      ls_remote(fn
        %{credentials: nil} -> :unauthorized
        %{credentials: credentials} -> exit({:failed, credentials})
      end)

    assert log =~ "the authorize function exited"
  end

  test "an authorize that returns something else logs no credentials and refuses" do
    log =
      ls_remote(fn
        %{credentials: nil} -> :unauthorized
        %{credentials: credentials} -> {:error, credentials}
      end)

    assert log =~ "the authorize function returned something other than"
  end

  # The options hold the store's secrets, so a failing config function is logged by
  # kind, like authorize.
  test "a config function that fails, or options that are wrong, log no values" do
    store = GitServer.TestStore.fresh()

    for {config, expected} <- [
          {fn -> raise "cannot connect with #{@password}" end,
           "the config function raised RuntimeError"},
          {fn -> {:ok, @password} end,
           "the config function returned something other than a keyword list or map"},
          {fn -> [store: store, authorize: fn _ -> :ok end, colour: @password] end,
           "unknown GitServer.Plug options: :colour"},
          {fn -> [store: @password, authorize: fn _ -> :ok end] end,
           "GitServer.Plug needs a :store and an :authorize function of one argument"},
          {fn -> %URI{host: @password} end,
           "the config function returned something other than a keyword list or map"},
          {fn -> [store: store, authorize: fn _ -> :ok end, max_pack_bytes: @password] end,
           "GitServer.Plug options must be non-negative integers: :max_pack_bytes"},
          {fn -> [store: store, authorize: fn _ -> :ok end, push_deadline_ms: nil] end,
           "GitServer.Plug options must be integers of milliseconds: :push_deadline_ms"},
          {fn -> [store: store, authorize: fn _ -> :ok end, download_concurrency: 0] end,
           "GitServer.Plug's :download_concurrency must be a positive integer"},
          {fn -> [store: store, authorize: fn _ -> :ok end, download_concurrency: nil] end,
           "GitServer.Plug's :download_concurrency must be a positive integer"},
        ] do
      server = TestServer.start!(config: config)

      log =
        capture_log(fn ->
          {output, 128} = git(["ls-remote", server.url <> "/repo"])
          assert output =~ "remote: Server error"
        end)

      assert log =~ expected
      refute log =~ @password
    end
  end

  test "a config function that fails is a server error", %{tmp_dir: tmp_dir} do
    server = TestServer.start!(config: fn -> raise "broken host config" end)

    log =
      capture_log(fn ->
        {output, 128} = git(["clone", "-q", server.url <> "/repo", Path.join(tmp_dir, "c")])
        assert output =~ "remote: Server error\n"
        assert output =~ "The requested URL returned error: 500"
      end)

    assert log =~ "the config function raised RuntimeError"
  end

  test "a before_update that fails refuses the push and logs no content", %{tmp_dir: tmp_dir} do
    checks = [
      fn _ -> raise "secret content" end,
      fn _ -> throw("secret content") end,
      fn _ -> exit("secret content") end,
      fn _ -> {:reject, :not_a_string} end,
      fn _ ->
        spawn_link(fn -> exit("secret content") end)
        Process.sleep(:infinity)
      end,
    ]

    local = init!(Path.join(tmp_dir, "local"))
    commit!(local, "README", "hello\n")
    check = fn push -> Enum.at(checks, String.to_integer(push.repo)).(push) end
    server = TestServer.start!(before_update: check)

    for i <- 0..(length(checks) - 1) do
      log =
        capture_log(fn ->
          {output, 1} = git(["push", TestServer.url(server, "#{i}"), "main"], cd: local)
          assert output =~ ~r/remote: The server could not check this push.\s*\n/
          assert output =~ " ! [remote rejected] main -> main (push check failed)\n"
        end)

      assert log =~ "the before_update function"
      refute log =~ "secret"
      assert refs(server, "#{i}") == %{}
    end
  end

  test "an after_update that fails is logged by kind and doesn't affect the push",
       %{tmp_dir: tmp_dir} do
    secret = "content-4d1e-distinctive"

    server =
      TestServer.start!(
        after_update: fn push -> raise "webhook failed for #{secret} #{inspect(push)}" end
      )

    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "a", secret)

    log =
      capture_log(fn ->
        TestServer.await_post(server, fn ->
          {output, 0} = git(["push", TestServer.url(server, "r"), "main"], cd: local)
          assert output =~ "* [new branch]      main -> main"
        end)
      end)

    assert log =~ "the after_update function raised RuntimeError"
    refute log =~ secret
    refute log =~ head
  end
end
