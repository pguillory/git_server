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
  end

  test "an authorize that returns something else logs no credentials and refuses" do
    log =
      ls_remote(fn
        %{credentials: nil} -> :unauthorized
        %{credentials: credentials} -> {:error, credentials}
      end)

    assert log =~ "the authorize function returned something other than"
  end
end
