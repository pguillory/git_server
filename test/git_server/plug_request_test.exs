defmodule GitServer.PlugRequestTest do
  # Requests git itself never sends, through Plug.Test.
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias GitServer.PktLine

  setup do
    test = self()

    authorize = fn request ->
      send(test, {:authorize, request.repo, request.credentials, request.conn})
      :ok
    end

    %{opts: GitServer.Plug.init(store: GitServer.TestStore.fresh(), authorize: authorize)}
  end

  defp call(conn, opts) do
    conn |> put_req_header("git-protocol", "version=2") |> GitServer.Plug.call(opts)
  end

  defp ls_refs_body(arguments \\ []) do
    IO.iodata_to_binary([
      PktLine.encode("command=ls-refs\n"),
      PktLine.encode("object-format=sha1\n"),
      PktLine.delim(),
      Enum.map(arguments, &PktLine.encode/1),
      PktLine.flush(),
    ])
  end

  defp post(path, body) do
    conn(:post, path, body)
    |> put_req_header("content-type", "application/x-git-upload-pack-request")
  end

  test "bad repository names are not found, before authorization", %{opts: opts} do
    for path <- [
          "/a%2Fb/info/refs",
          "/a/../b/info/refs",
          "/../b/info/refs",
          "/a/./b/info/refs",
          "/.hidden/info/refs",
          "/a//b/info/refs",
          "/a\\b/info/refs",
          "/a%00b/info/refs",
          "/x.git.git/info/refs",
          "/x.git/y/info/refs",
          "/a b/info/refs",
          "/#{String.duplicate("a", 201)}/info/refs",
          "/info/refs",
        ] do
      conn = call(conn(:get, path <> "?service=git-upload-pack"), opts)
      assert conn.status == 404, path
    end

    refute_received {:authorize, _, _, _}

    conn =
      call(
        conn(:get, "/#{String.duplicate("a", 200)}.git/info/refs?service=git-upload-pack"),
        opts
      )

    assert conn.status == 200
  end

  test "unknown routes are not found", %{opts: opts} do
    assert call(conn(:get, "/repo/info/refs"), opts).status == 404
    assert call(conn(:get, "/repo/info/refs?service=git-other"), opts).status == 404
    assert call(conn(:get, "/repo/HEAD"), opts).status == 404
    assert call(conn(:get, "/repo/git-upload-pack"), opts).status == 404
    assert call(conn(:put, "/repo/git-upload-pack"), opts).status == 404
  end

  test "credentials from one well-formed Basic header, which is then dropped", %{opts: opts} do
    basic = "Basic " <> Base.encode64("user:pa:ss")

    call(
      conn(:get, "/repo/info/refs?service=git-upload-pack")
      |> put_req_header("authorization", basic),
      opts
    )

    assert_received {:authorize, "repo", {"user", "pa:ss"}, conn}
    assert get_req_header(conn, "authorization") == [basic]

    call(
      conn(:get, "/repo/info/refs?service=git-upload-pack")
      |> put_req_header("authorization", "basic " <> Base.encode64("u:p")),
      opts
    )

    assert_received {:authorize, "repo", {"u", "p"}, _conn}

    for header <- ["Bearer abc", "Basic !!!", "Basic " <> Base.encode64("no-colon")] do
      call(
        conn(:get, "/repo/info/refs?service=git-upload-pack")
        |> put_req_header("authorization", header),
        opts
      )

      assert_received {:authorize, "repo", nil, _conn}
    end

    conn = conn(:get, "/repo/info/refs?service=git-upload-pack")

    conn = %{
      conn
      | req_headers: [{"authorization", basic}, {"authorization", basic} | conn.req_headers],
    }

    conn = call(conn, opts)
    assert_received {:authorize, "repo", nil, _conn}
    assert get_req_header(conn, "authorization") == []
  end

  test "the v2 advertisement", %{opts: opts} do
    conn = call(conn(:get, "/repo/info/refs?service=git-upload-pack"), opts)

    assert get_resp_header(conn, "content-type") == [
             "application/x-git-upload-pack-advertisement",
           ]

    assert get_resp_header(conn, "cache-control") == ["no-cache"]

    assert PktLine.decode(conn.resp_body) ==
             {:ok,
              [
                "version 2\n",
                "agent=git_server/#{GitServer.version()}\n",
                "ls-refs=unborn\n",
                "fetch=shallow\n",
                "object-format=sha1\n",
                :flush,
              ]}

    conn =
      conn(:get, "/repo/info/refs?service=git-upload-pack")
      |> put_req_header("git-protocol", "a=b:version=2")

    assert GitServer.Plug.call(conn, opts).status == 200
  end

  test "the receive-pack advertisement of an empty repository", %{opts: opts} do
    conn = GitServer.Plug.call(conn(:get, "/repo/info/refs?service=git-receive-pack"), opts)

    assert get_resp_header(conn, "content-type") == [
             "application/x-git-receive-pack-advertisement",
           ]

    assert {:ok, ["# service=git-receive-pack\n", :flush, first, :flush]} =
             PktLine.decode(conn.resp_body)

    assert [ref, capabilities] = String.split(first, "\0")
    assert ref == String.duplicate("0", 40) <> " capabilities^{}"
    assert String.split(capabilities) -- ["agent=git_server/#{GitServer.version()}"] == ~w(
      report-status delete-refs side-band-64k quiet atomic ofs-delta no-thin object-format=sha1
    )
  end

  test "ls-refs filters by prefix and reports an unborn HEAD", %{opts: opts} do
    conn =
      call(
        post("/repo/git-upload-pack", ls_refs_body(["symrefs", "unborn", "ref-prefix HEAD"])),
        opts
      )

    assert get_resp_header(conn, "content-type") == ["application/x-git-upload-pack-result"]

    assert PktLine.decode(conn.resp_body) ==
             {:ok, ["unborn HEAD symref-target:refs/heads/main\n", :flush]}

    conn = call(post("/repo/git-upload-pack", ls_refs_body(["ref-prefix refs/tags/"])), opts)
    assert PktLine.decode(conn.resp_body) == {:ok, [:flush]}

    conn = call(post("/repo/git-upload-pack", ls_refs_body(["bogus"])), opts)
    assert {:ok, ["ERR unsupported ls-refs argument" <> _]} = PktLine.decode(conn.resp_body)
  end

  test "upload-pack errors", %{opts: opts} do
    conn = call(post("/repo/git-upload-pack", "0000"), opts)
    assert {conn.status, conn.resp_body} == {200, ""}

    conn = GitServer.Plug.call(post("/repo/git-upload-pack", "0000"), opts)
    assert {conn.status, conn.resp_body} == {200, ""}

    conn = GitServer.Plug.call(post("/repo/git-upload-pack", ls_refs_body()), opts)
    assert conn.status == 400

    for {body, error} <- [
          {"zzzz", "ERR invalid pkt-line length"},
          {"0020command=ls-r", "ERR truncated pkt-line"},
          {ls_refs_body() |> String.replace("object-format=sha1", "object-format=sha2"),
           "ERR unsupported object-format"},
          {IO.iodata_to_binary([
             PktLine.encode("command=fetch\n"),
             PktLine.delim(),
             PktLine.flush(),
           ]), "ERR fetch needs at least one want"},
          {IO.iodata_to_binary([PktLine.encode("command=other\n"), PktLine.flush()]),
           "ERR unknown command"},
          {IO.iodata_to_binary([PktLine.encode("nothing\n"), PktLine.flush()]),
           "ERR malformed request"},
          {IO.iodata_to_binary([PktLine.encode("command=\n"), PktLine.flush()]),
           "ERR unknown command"},
          {IO.iodata_to_binary([
             PktLine.encode("command=ls-refs\n"),
             PktLine.delim(),
             "0004",
             PktLine.flush(),
           ]), "ERR unsupported ls-refs argument"},
          {IO.iodata_to_binary([
             PktLine.encode("command=ls-refs\n"),
             PktLine.encode("object-format=" <> String.duplicate("x", 65_502)),
             PktLine.flush(),
           ]), "ERR unsupported object-format"},
        ] do
      conn = call(post("/repo/git-upload-pack", body), opts)
      assert conn.status == 200
      assert {:ok, [message]} = PktLine.decode(conn.resp_body)
      assert String.starts_with?(message, error), inspect({body, message})
    end
  end

  test "gzip request bodies, an oversized body and a gzip bomb", %{opts: opts} do
    gzip = fn body ->
      post("/repo/git-upload-pack", :zlib.gzip(body))
      |> put_req_header("content-encoding", "gzip")
    end

    conn = call(gzip.(ls_refs_body(["unborn"])), opts)
    assert PktLine.decode(conn.resp_body) == {:ok, ["unborn HEAD\n", :flush]}

    # Answered in-protocol, since git shows a POST's error status to no one.
    error = fn conn, opts -> PktLine.decode(call(conn, opts).resp_body) end
    too_large = {:ok, ["ERR request too large (limit 10 MB)\n"]}

    assert error.(post("/repo/git-upload-pack", String.duplicate("0", 10_000_001)), opts) ==
             too_large

    assert error.(gzip.(String.duplicate("0", 10_000_001)), opts) == too_large

    small = GitServer.Plug.init(Keyword.put(opts, :max_request_bytes, 1000))

    assert error.(gzip.(String.duplicate("x", 1001)), small) ==
             {:ok, ["ERR request too large (limit 1 KB)\n"]}

    assert call(gzip.(String.duplicate("x", 1000)), small).status == 200

    truncated = binary_part(:zlib.gzip(ls_refs_body()), 0, 20)
    conn = post("/repo/git-upload-pack", truncated) |> put_req_header("content-encoding", "gzip")
    assert error.(conn, opts) == {:ok, ["ERR malformed gzip request body\n"]}

    conn = post("/repo/git-upload-pack", "x") |> put_req_header("content-encoding", "br")
    assert error.(conn, opts) == {:ok, ["ERR unsupported Content-Encoding\n"]}
  end

  test "the receive-pack advertisement lists refs, capabilities on the first only", %{opts: opts} do
    store = opts[:store]
    a = String.duplicate("a", 40)
    b = String.duplicate("b", 40)
    state = %GitServer.State{refs: %{"refs/tags/v1" => a, "refs/heads/main" => b}}
    {:ok, _} = GitServer.Repository.put_state(store, "repo", state, :absent)

    conn = GitServer.Plug.call(conn(:get, "/repo/info/refs?service=git-receive-pack"), opts)

    assert {:ok, ["# service=git-receive-pack\n", :flush, first, second, :flush]} =
             PktLine.decode(conn.resp_body)

    assert [^b <> " refs/heads/main", "report-status " <> _] = String.split(first, "\0")
    assert second == a <> " refs/tags/v1\n"
  end

  test "401 carries a Basic challenge, 403 does not" do
    for {answer, status} <- [unauthorized: 401, forbidden: 403] do
      opts =
        GitServer.Plug.init(store: GitServer.TestStore.fresh(), authorize: fn _ -> answer end)

      conn = call(conn(:get, "/repo/info/refs?service=git-upload-pack"), opts)
      assert conn.status == status

      assert get_resp_header(conn, "www-authenticate") ==
               if(status == 401, do: [~s(Basic realm="git")], else: [])
    end
  end
end
