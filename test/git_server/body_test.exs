defmodule GitServer.BodyTest do
  use ExUnit.Case, async: true
  import GitServer.Body
  import Plug.Test
  import Plug.Conn

  @tag :tmp_dir
  test "copy_to_file streams the rest of a body, plain or gzip", %{tmp_dir: tmp_dir} do
    body = :crypto.strong_rand_bytes(300_000)

    for {conn, name} <- [
          {conn(:post, "/", body), "plain"},
          {conn(:post, "/", :zlib.gzip(body)) |> put_req_header("content-encoding", "gzip"),
           "gzip"},
        ] do
      {:ok, reader} = reader(conn, 1_000_000)
      {:ok, first, reader} = next(reader)
      path = Path.join(tmp_dir, name)
      assert {:ok, %Plug.Conn{}} = copy_to_file(reader, first, path)
      assert File.read!(path) == body
    end

    {:ok, reader} = reader(conn(:post, "/", body), 100_000)
    path = Path.join(tmp_dir, "capped")
    assert {:error, :too_large, %Plug.Conn{}} = copy_to_file(reader, "", path)
    refute File.exists?(path)
  end
end
