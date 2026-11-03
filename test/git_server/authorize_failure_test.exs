defmodule GitServer.AuthorizeFailureTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import GitServer.TestGit
  alias GitServer.TestServer

  @password "pw-7f3a9c-distinctive"

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
    assert log =~ "test/git_server/authorize_failure_test.exs"
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
end
