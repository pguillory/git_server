defmodule GitServer.HTTP do
  @moduledoc false
  # The HTTP responses the Plug and the protocol modules send: advertisements,
  # service results, and plain-text errors, which git shows to the user as
  # `remote: ...` lines.

  import Plug.Conn
  require Logger

  def advertise(conn, service, body) do
    conn
    |> put_resp_content_type("application/x-#{service}-advertisement", nil)
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, body)
  end

  # A service's whole response.
  def result(conn, service, body) do
    conn |> result_headers(service) |> send_resp(200, body)
  end

  # Starts a service's streamed response; the caller sends the rest with `chunk/2`.
  def chunked_result(conn, service) do
    conn |> result_headers(service) |> send_chunked(200)
  end

  defp result_headers(conn, service) do
    conn
    |> put_resp_content_type("application/x-#{service}-result", nil)
    |> put_resp_header("cache-control", "no-cache")
  end

  def body_error(conn, :too_large), do: text(conn, 413, "Request body too large")
  def body_error(conn, :bad_gzip), do: text(conn, 400, "Malformed gzip request body")

  def body_error(conn, :unsupported_encoding),
    do: text(conn, 415, "Unsupported Content-Encoding")

  def body_error(conn, _reason), do: text(conn, 400, "Could not read the request body")

  # Store messages hold no secrets, but stay out of the response all the same.
  def store_error(conn, reason) do
    Logger.error("git_server: store error: #{inspect(reason)}")
    text(conn, 500, "Storage error")
  end

  # Git shows a text/plain error body to the user as `remote: ...` lines.
  def text(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(status, message <> "\n")
  end

  # The agent capability's value.
  def agent do
    "git_server/#{GitServer.version()}"
  end
end
