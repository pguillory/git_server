defmodule GitServer.ErrorsTest do
  # What the real git client prints for each failure in the README's "When something
  # goes wrong" table. Each assertion is a line git prints, so a change here is a
  # change to that table.
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import GitServer.TestGit
  alias GitServer.{OutageStore, TestServer}

  @moduletag :tmp_dir

  # A repository on `server` with one commit pushed, and its local clone.
  defp pushed!(server, tmp_dir) do
    local = Path.join(tmp_dir, "local")
    {_, 0} = git(["init", "-q", "-b", "main", local])
    commit!(local, "a", "a\n")
    {_, 0} = git(["push", TestServer.url(server, "repo"), "main"], cd: local)
    local
  end

  defp commit!(dir, file, content) do
    File.write!(Path.join(dir, file), content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", "change #{file}"], cd: dir)
    {id, 0} = git(["rev-parse", "HEAD"], cd: dir)
    String.trim(id)
  end

  defp clone(server, tmp_dir, opts \\ []) do
    url = Keyword.get(opts, :url, TestServer.url(server, "repo"))
    git(["clone", "-q", url, Path.join(tmp_dir, "clone-#{System.unique_integer([:positive])}")])
  end

  defp push(server, local, refspec \\ "main") do
    git(["push", TestServer.url(server, "repo"), refspec], cd: local)
  end

  test "authentication, authorization and names", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = pushed!(server, tmp_dir)

    {output, 128} = clone(server, tmp_dir, url: TestServer.url(server, "repo", "user", "wrong"))
    assert output =~ "remote: Authentication failed: wrong or missing username or password\n"
    assert output =~ "fatal: Authentication failed for "

    {output, 128} = clone(server, tmp_dir, url: server.url <> "/repo")
    assert output =~ "fatal: could not read Username for "
    assert output =~ "terminal prompts disabled"

    {output, 128} = clone(server, tmp_dir, url: TestServer.url(server, ".hidden"))
    assert output =~ "remote: Not found\n"
    assert output =~ "fatal: repository "
    assert output =~ " not found"

    forbidding = fn request -> if request.credentials, do: :forbidden, else: :unauthorized end
    forbidden = TestServer.start!(store: server.store, authorize: forbidding)
    {output, 128} = clone(forbidden, tmp_dir)

    assert output =~
             "remote: Access denied: you can't read this repository, or it doesn't exist\n"

    assert output =~ "The requested URL returned error: 403"

    {output, 128} = push(forbidden, local)

    assert output =~
             "remote: Access denied: you can't push to this repository, or it doesn't exist\n"
  end

  test "fetching with protocol v0", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    pushed!(server, tmp_dir)
    url = TestServer.url(server, "repo")

    {output, 128} = git(["-c", "protocol.version=0", "clone", "-q", url, Path.join(tmp_dir, "c")])

    assert output =~
             "remote: git_server needs Git protocol version 2 to fetch (git 2.26 or later, protocol.version=2)\n"
  end

  test "a host callback that fails is a server error", %{tmp_dir: tmp_dir} do
    server = TestServer.start!(config: fn -> raise "broken host config" end)

    log =
      capture_log(fn ->
        {output, 128} = clone(server, tmp_dir, url: server.url <> "/repo")
        assert output =~ "remote: Server error\n"
        assert output =~ "The requested URL returned error: 500"
      end)

    assert log =~ "the config function raised RuntimeError"
  end

  test "storage failures, at each step", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = pushed!(server, tmp_dir)
    commit!(local, "b", "b\n")
    everything = TestServer.start!(store: OutageStore.wrap(server.store, [:get], ~r/./, "down"))
    packs = OutageStore.wrap(server.store, [:get_file, :put_file], ~r/packs/, "down")
    packs = TestServer.start!(store: packs)

    log =
      capture_log(fn ->
        # The push's ref advertisement, git's first request.
        {output, 128} = push(everything, local)
        assert output =~ "remote: the server's storage failed; try again later\n"
        assert output =~ "The requested URL returned error: 500"

        # ls-refs, then fetch.
        {output, 128} = clone(everything, tmp_dir)
        assert output =~ "fatal: remote error: the server's storage failed; try again later\n"
        {output, 128} = clone(packs, tmp_dir)
        assert output =~ "fatal: remote error: the server's storage failed; try again later\n"

        # Downloading the repository's packs, or storing the new one.
        {output, 1} = push(packs, local)
        assert output =~ " ! [remote rejected] main -> main (storage failed, try again later)\n"
      end)

    assert log =~ ~s(store error: "down")
    refute log =~ "error] ** "
  end

  test "push limits", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = pushed!(server, tmp_dir)
    File.write!(Path.join(local, "random"), :crypto.strong_rand_bytes(5_000))
    {_, 0} = git(["add", "-A"], cd: local)
    {_, 0} = git(["commit", "-q", "-m", "random"], cd: local)

    small = TestServer.start!(store: server.store, max_pack_bytes: 2_000)
    {output, 1} = push(small, local)
    assert output =~ "error: remote unpack failed: pack too large (limit 2 KB)\n"
    assert output =~ " ! [remote rejected] main -> main (unpacker error)\n"

    objects = TestServer.start!(store: server.store, max_object_bytes: 1_000)
    {output, 1} = push(objects, local)
    assert output =~ "error: remote unpack failed: object too large (limit 1 KB)\n"

    count = TestServer.start!(store: server.store, max_objects: 2)
    {output, 1} = push(count, local)
    assert output =~ "error: remote unpack failed: too many objects in pack (limit 2)\n"
  end

  # Over git's 1 MB post buffer, git streams the pack chunked; with a larger buffer it
  # sends a Content-Length. Either way it is still sending when the server has seen
  # enough, and the report must still reach it.
  test "a push far over the pack limit gets its report", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = pushed!(server, tmp_dir)
    File.write!(Path.join(local, "random"), :crypto.strong_rand_bytes(20_000_000))
    {_, 0} = git(["add", "-A"], cd: local)
    {_, 0} = git(["commit", "-q", "-m", "random"], cd: local)
    small = TestServer.start!(store: server.store, max_pack_bytes: 6_000_000)
    url = TestServer.url(small, "repo")

    for args <- [["push"], ["-c", "http.postBuffer=100000000", "push"]] do
      {output, 1} = git(args ++ [url, "main"], cd: local)
      assert output =~ "error: remote unpack failed: pack too large (limit 6 MB)\n"
      assert output =~ " ! [remote rejected] main -> main (unpacker error)\n"
      refute output =~ "Broken pipe"
    end

    # Past four times the limit, streamed or declared, the server replies without
    # reading on and closes the connection, so what git shows varies; the push never
    # lands.
    tiny = TestServer.start!(store: server.store, max_pack_bytes: 1_000_000)
    {:ok, before, etag} = GitServer.Repository.read_state(server.store, "repo")

    for args <- [["push"], ["-c", "http.postBuffer=100000000", "push"]] do
      {_output, status} = git(args ++ [TestServer.url(tiny, "repo"), "main"], cd: local)
      assert status != 0
      assert GitServer.Repository.read_state(server.store, "repo") == {:ok, before, etag}
    end
  end

  # Git can't be made to send this slowly, so a raw client: the server stops waiting
  # for the rest of an oversized body at the push deadline and still reports. The
  # body passes the cap in the server's second 64 KB read, and then stalls.
  test "a client too slow to drain still gets its report", %{tmp_dir: _tmp_dir} do
    server =
      TestServer.start!(max_pack_bytes: 100_000, max_command_bytes: 200, push_deadline_ms: 300)

    %URI{port: port, userinfo: userinfo} = URI.parse(TestServer.url(server, "repo"))
    zero = String.duplicate("0", 40)
    id = String.duplicate("1", 40)
    commands = GitServer.PktLine.encode("#{zero} #{id} refs/heads/main\0report-status\n")
    body = IO.iodata_to_binary([commands, GitServer.PktLine.flush(), :binary.copy("x", 140_000)])
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "POST /repo/git-receive-pack HTTP/1.1\r\nhost: 127.0.0.1\r\n",
        "authorization: Basic #{Base.encode64(userinfo)}\r\n",
        "content-type: application/x-git-receive-pack-request\r\n",
        "transfer-encoding: chunked\r\n\r\n",
        Integer.to_string(byte_size(body), 16),
        "\r\n",
        body,
        "\r\n",
      ])

    # Then nothing more, until the server answers.
    response = receive_all(socket, "")
    :gen_tcp.close(socket)
    assert response =~ ~r/\AHTTP\/1.1 200 /
    assert response =~ ~r/\r\nconnection: close\r\n/i
    assert response =~ "unpack pack too large (limit 100 KB)\n"
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> receive_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  test "a push with more ref commands than the limit allows", %{tmp_dir: tmp_dir} do
    server = TestServer.start!(max_command_bytes: 1_000)
    local = Path.join(tmp_dir, "local")
    {_, 0} = git(["init", "-q", "-b", "main", local])
    commit!(local, "a", "a\n")
    for n <- 1..30, do: {_, 0} = git(["tag", "release-#{n}"], cd: local)

    {output, 1} = push(server, local, "refs/tags/*")
    assert output =~ "error: remote unpack failed: too many ref commands (limit 1 KB)\n"

    assert output =~
             ~r/ ! \[remote failure\] +release-1 -> release-1 \(remote failed to report status\)\n/

    # The first command alone over the cap.
    tiny = TestServer.start!(store: server.store, max_command_bytes: 100)
    {output, 1} = push(tiny, local, "main")
    assert output =~ "error: remote unpack failed: too many ref commands (limit 100 bytes)\n"
  end

  test "a push that keeps losing the race", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = pushed!(server, tmp_dir)
    commit!(local, "b", "b\n")
    losing = OutageStore.wrap(server.store, [:put], ~r{/state$}, :precondition_failed)
    losing = TestServer.start!(store: losing, push_deadline_ms: 200)

    {output, 1} = push(losing, local)

    assert output =~
             " ! [remote rejected] main -> main (failed to update ref, too many pushes at once)\n"
  end

  test "a push the host's check refuses, or can't run", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = pushed!(server, tmp_dir)
    commit!(local, "b", "b\n")

    refusing = fn _push -> {:reject, "config.toml: unknown key"} end
    refusing = TestServer.start!(store: server.store, before_update: refusing)
    {output, 1} = push(refusing, local)
    assert output =~ ~r/remote: config.toml: unknown key\s*\n/
    assert output =~ " ! [remote rejected] main -> main (declined)\n"

    failing = TestServer.start!(store: server.store, before_update: fn _push -> raise "bug" end)

    log =
      capture_log(fn ->
        {output, 1} = push(failing, local)
        assert output =~ ~r/remote: The server could not check this push.\s*\n/
        assert output =~ " ! [remote rejected] main -> main (push check failed)\n"
      end)

    assert log =~ "the before_update function raised RuntimeError"
  end

  test "a fetch of an object no ref reaches", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    local = pushed!(server, tmp_dir)
    orphan = commit!(local, "b", "b\n")
    {_, 0} = push(server, local, "main:refs/heads/tmp")
    {_, 0} = push(server, local, ":refs/heads/tmp")
    {_, 0} = clone(server, tmp_dir, url: TestServer.url(server, "repo"))
    [clone] = Path.wildcard(Path.join(tmp_dir, "clone-*"))

    {output, 128} = git(["fetch", "origin", orphan], cd: clone)
    assert output =~ "fatal: remote error: upload-pack: not our ref #{orphan}\n"
  end
end
