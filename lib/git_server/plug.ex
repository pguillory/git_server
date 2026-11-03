defmodule GitServer.Plug do
  @moduledoc """
  Serves Git's smart HTTP protocol. Mount it before any body parser, for example

      forward "/git", to: GitServer.Plug, init_opts: [config: {MyApp.Git, :config, []}]

  Options are those of `GitServer.Config`, or `config:` naming a function that
  returns them on each request.

  Routes, under the repository's path (see `GitServer.RepoName`):

  - `GET <repo>/info/refs?service=git-upload-pack`: the protocol v2 capability
    advertisement. Fetching needs protocol v2 (git's default since 2.26); a client
    asking for v0 gets HTTP 400 saying so.
  - `POST <repo>/git-upload-pack`: v2 commands, `ls-refs` and `fetch` (see
    `GitServer.UploadPack`).
  - `GET <repo>/info/refs?service=git-receive-pack` and
    `POST <repo>/git-receive-pack`: push, over protocol v0 (see
    `GitServer.ReceivePack`).

  Anything else is 404.

  ## Authorization

  Before touching the store, the Plug calls the `:authorize` function with a map:

  - `repo`: the canonical repository name.
  - `access`: `:read` for upload-pack, `:write` for receive-pack.
  - `credentials`: `{username, password}` from HTTP Basic, or `nil` when there is
    no Authorization header, more than one, or a malformed one.
  - `conn`: the `Plug.Conn`.

  It returns `:ok`, `:unauthorized` (HTTP 401 with a Basic challenge, so git asks
  for credentials) or `:forbidden` (403). The Authorization header is dropped from
  the conn once checked, and this library never logs credentials (see the README on
  the HTTP server's own crash logs). If the function raises, throws, exits or
  returns anything else, the request is refused with HTTP 500 and the log says only
  which: for a raise, throw or exit, its kind, an exception's module and a
  stacktrace without arguments; for a return, not the value. The same goes for a
  `config:` function that fails and for wrong options, which the log names without
  their values.

  A 401 or 403 body is one line, which git shows as a `remote:` line; a 403 doesn't
  say whether the repository exists. After `info/refs`, git shows no HTTP error body,
  so the protocol modules answer the failures git can meet in-protocol.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger
  alias GitServer.{Body, Config, HTTP, PktLine, RepoName, ReceivePack, UploadPack}

  @impl true
  def init(opts) do
    opts
  end

  @impl true
  def call(conn, opts) do
    with {:ok, segments, service} <- route(conn),
         {:ok, repo} <- repo_name(conn, segments) do
      access = if service in [:upload_pack, :upload_pack_refs], do: :read, else: :write

      with {:ok, config} <- config(conn, opts),
           {:ok, conn} <- authorize(conn, config, repo, access) do
        serve(conn, config, repo, service)
      else
        {:error, conn} -> conn
      end
    else
      :not_found -> HTTP.text(conn, 404, "Not found")
    end
    |> halt()
  end

  defp route(%{method: "GET", path_info: path_info} = conn) do
    case Enum.split(path_info, -2) do
      {segments, ["info", "refs"]} ->
        case fetch_query_params(conn).query_params["service"] do
          "git-upload-pack" -> {:ok, segments, :upload_pack_refs}
          "git-receive-pack" -> {:ok, segments, :receive_pack_refs}
          _ -> :not_found
        end

      _ ->
        :not_found
    end
  end

  defp route(%{method: "POST", path_info: path_info}) do
    case Enum.split(path_info, -1) do
      {segments, ["git-upload-pack"]} -> {:ok, segments, :upload_pack}
      {segments, ["git-receive-pack"]} -> {:ok, segments, :receive_pack}
      _ -> :not_found
    end
  end

  defp route(_conn) do
    :not_found
  end

  defp repo_name(conn, segments) do
    with :error <- RepoName.parse(conn.request_path, segments), do: :not_found
  end

  # The options hold the store's secrets, so a failure is logged without them.
  defp config(conn, opts) do
    case Config.resolve(opts) do
      {:ok, config} ->
        {:ok, config}

      {:error, description} ->
        Logger.error("git_server: #{description}")
        {:error, HTTP.text(conn, 500, "Server error")}
    end
  end

  defp authorize(conn, config, repo, access) do
    request = %{repo: repo, access: access, credentials: credentials(conn), conn: conn}
    # delete_req_header/2 would drop only the first of several.
    conn = %{conn | req_headers: Enum.reject(conn.req_headers, &match?({"authorization", _}, &1))}

    case call_authorize(config.authorize, request) do
      :ok ->
        {:ok, conn}

      :unauthorized ->
        conn = put_resp_header(conn, "www-authenticate", ~s(Basic realm="git"))

        {:error,
         HTTP.text(conn, 401, "Authentication failed: wrong or missing username or password")}

      # Never says whether the repository exists.
      :forbidden ->
        what = if access == :read, do: "read", else: "push to"

        {:error,
         HTTP.text(
           conn,
           403,
           "Access denied: you can't #{what} this repository, or it doesn't exist"
         )}

      {:failed, what} ->
        Logger.error("git_server: the authorize function #{what}")
        {:error, HTTP.text(conn, 500, "Server error")}
    end
  end

  # The request holds the password and the Authorization header, so a failure is
  # caught here and logged by kind only; uncaught, the HTTP server's crash report
  # would print the call's arguments.
  defp call_authorize(authorize, request) do
    case authorize.(request) do
      result when result in [:ok, :unauthorized, :forbidden] -> result
      _other -> {:failed, "returned something other than :ok, :unauthorized or :forbidden"}
    end
  catch
    kind, reason -> {:failed, GitServer.Failure.describe(kind, reason, __STACKTRACE__)}
  end

  defp credentials(conn) do
    # The scheme name is case-insensitive (RFC 7617).
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, encoded] <- String.split(header, " ", parts: 2),
         "basic" <- String.downcase(scheme),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)),
         [username, password] <- :binary.split(decoded, ":") do
      {username, password}
    else
      _ -> nil
    end
  end

  defp serve(conn, _config, _repo, :upload_pack_refs) do
    if protocol_v2?(conn) do
      HTTP.advertise(conn, "git-upload-pack", [
        PktLine.encode("version 2\n"),
        PktLine.encode("agent=#{HTTP.agent()}\n"),
        PktLine.encode("ls-refs=unborn\n"),
        PktLine.encode("fetch=shallow\n"),
        PktLine.encode("object-format=sha1\n"),
        PktLine.flush(),
      ])
    else
      needs_v2(conn)
    end
  end

  defp serve(conn, config, repo, :receive_pack_refs) do
    ReceivePack.advertise(conn, config, repo)
  end

  defp serve(conn, config, repo, :upload_pack) do
    # A body of just a flush is git's probe before a large request, which git sends
    # without its Git-Protocol header.
    case Body.read(conn, config.max_request_bytes) do
      {:ok, "0000", conn} ->
        HTTP.result(conn, "git-upload-pack", [])

      {:ok, body, conn} ->
        if protocol_v2?(conn),
          do: UploadPack.command(conn, config, repo, body),
          else: needs_v2(conn)

      # After info/refs git shows only an in-protocol error.
      {:error, reason, conn} ->
        UploadPack.body_error(conn, reason, config)
    end
  end

  defp serve(conn, config, repo, :receive_pack) do
    ReceivePack.push(conn, config, repo)
  end

  # Git-Protocol holds `:`-separated key=value entries.
  defp protocol_v2?(conn) do
    conn
    |> get_req_header("git-protocol")
    |> Enum.flat_map(&String.split(&1, ":"))
    |> Enum.member?("version=2")
  end

  defp needs_v2(conn) do
    HTTP.text(
      conn,
      400,
      "git_server needs Git protocol version 2 to fetch (git 2.26 or later, protocol.version=2)"
    )
  end
end
