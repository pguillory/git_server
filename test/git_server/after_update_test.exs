defmodule GitServer.AfterUpdateTest do
  # The host's after_update function, with the real git client.
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
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

    push_and_wait(declining, fn ->
      {_, 1} = git(["push", TestServer.url(declining, "r"), "main"], cd: local)
    end)

    refute_received {:landed, _, _, _}

    # A push the server refuses: a branch that names a tag object.
    {_, 0} = git(["tag", "-a", "v1", "-m", "v1"], cd: local)
    server = observing(store: store)

    push_and_wait(server, fn ->
      {output, 1} = git(["push", TestServer.url(server, "r"), "v1:refs/heads/v1"], cd: local)
      assert output =~ "(not a commit)"
    end)

    refute_received {:landed, _, _, _}
  end

  # The function runs after the report is sent, so git can finish before it does. Runs
  # `fun` and waits for every push request to `server` to end.
  defp push_and_wait(server, fun) do
    test = self()
    port = URI.parse(server.url).port
    id = make_ref()

    :telemetry.attach(
      id,
      [:bandit, :request, :stop],
      &__MODULE__.request_stopped/4,
      {test, port, id}
    )

    try do
      fun.()
      assert_receive {:request_done, ^id}, 5_000
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def request_stopped(_event, _measurements, metadata, {test, port, id}) do
    case metadata do
      %{conn: %{port: ^port, method: "POST"}} -> send(test, {:request_done, id})
      _ -> :ok
    end
  end

  test "a failing one is logged by kind and doesn't affect the push", %{tmp_dir: tmp_dir} do
    secret = "content-4d1e-distinctive"

    server =
      TestServer.start!(
        after_update: fn push -> raise "webhook failed for #{secret} #{inspect(push)}" end
      )

    local = init!(Path.join(tmp_dir, "local"))
    head = commit!(local, "a", secret)

    log =
      capture_log(fn ->
        push_and_wait(server, fn ->
          {output, 0} = git(["push", TestServer.url(server, "r"), "main"], cd: local)
          assert output =~ "* [new branch]      main -> main"
        end)
      end)

    assert log =~ "the after_update function raised RuntimeError"
    refute log =~ secret
    refute log =~ head
  end
end
