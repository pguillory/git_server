defmodule GitServer.Body do
  @moduledoc """
  Reads a request body under a size cap, inflating `Content-Encoding: gzip` (git
  gzips large upload-pack requests). The cap applies to the bytes received and,
  for gzip, to the inflated bytes too, so a gzip bomb fails as soon as it passes the
  cap. Chunked bodies need nothing special: Plug delivers them decoded.

  `read/2` returns the whole body. For bodies too big to hold, `reader/2` and
  `next/1` hand it over chunk by chunk, and `copy_to_file/3` writes the rest of it
  to a file.

  The cap counts from the start of the body, across `next/1` and `copy_to_file/3`;
  a caller with a smaller cap for a first section enforces it itself. A reader not
  read to the end or to an error holds an inflater until `close/1`.

  Failures are `{:error, reason, conn}`, with `reason` one of `:too_large`,
  `:bad_gzip`, `:unsupported_encoding`, `{:file, posix}`, or the server's own
  reason from `Plug.Conn.read_body/2` (a timeout, a closed connection).
  """

  @chunk_bytes 65_536

  defstruct [:conn, :zlib, max_bytes: 0, raw: 0, inflated: 0, done: false]

  @doc "Reads the whole body: `{:ok, body, conn}` or `{:error, reason, conn}`."
  def read(conn, max_bytes) do
    with {:ok, reader} <- reader(conn, max_bytes) do
      collect(reader, [])
    end
  end

  defp collect(reader, acc) do
    case next(reader) do
      {:ok, chunk, reader} -> collect(reader, [acc | chunk])
      {:done, conn} -> {:ok, IO.iodata_to_binary(acc), conn}
      {:error, reason, conn} -> {:error, reason, conn}
    end
  end

  @doc "Starts reading `conn`'s body: `{:ok, reader}` or `{:error, reason, conn}`."
  def reader(conn, max_bytes) do
    case Plug.Conn.get_req_header(conn, "content-encoding") do
      [] ->
        {:ok, %__MODULE__{conn: conn, max_bytes: max_bytes}}

      [encoding] when encoding in ["gzip", "x-gzip"] ->
        zlib = :zlib.open()
        :ok = :zlib.inflateInit(zlib, 31)
        {:ok, %__MODULE__{conn: conn, zlib: zlib, max_bytes: max_bytes}}

      _ ->
        {:error, :unsupported_encoding, conn}
    end
  end

  @doc """
  The next piece of the (inflated) body: `{:ok, chunk, reader}`, `{:done, conn}` at
  the end, or `{:error, reason, conn}`. A chunk may be empty.
  """
  def next(%__MODULE__{done: true} = reader) do
    finish(reader)
  end

  def next(%__MODULE__{} = reader) do
    case Plug.Conn.read_body(reader.conn, length: @chunk_bytes, read_length: @chunk_bytes) do
      {more, data, conn} when more in [:ok, :more] ->
        reader = %{reader | conn: conn, raw: reader.raw + byte_size(data), done: more == :ok}

        cond do
          reader.raw > reader.max_bytes -> fail(reader, :too_large)
          reader.zlib == nil -> {:ok, data, reader}
          true -> inflate(reader, data)
        end

      {:error, reason} ->
        fail(reader, reason)
    end
  end

  defp inflate(reader, data) do
    case inflate_all(
           reader.zlib,
           :zlib.safeInflate(reader.zlib, data),
           [],
           reader.inflated,
           reader.max_bytes
         ) do
      {:ok, output, inflated} -> {:ok, output, %{reader | inflated: inflated}}
      {:error, reason} -> fail(reader, reason)
    end
  catch
    :error, _ -> fail(reader, :bad_gzip)
  end

  # safeInflate hands back bounded pieces, so the cap is checked as output grows.
  defp inflate_all(zlib, {state, output}, acc, inflated, max_bytes) do
    inflated = inflated + IO.iodata_length(output)

    cond do
      inflated > max_bytes ->
        {:error, :too_large}

      state == :continue ->
        inflate_all(zlib, :zlib.safeInflate(zlib, []), [acc | output], inflated, max_bytes)

      true ->
        {:ok, IO.iodata_to_binary([acc | output]), inflated}
    end
  end

  defp finish(%__MODULE__{zlib: nil, conn: conn}) do
    {:done, conn}
  end

  defp finish(%__MODULE__{zlib: zlib, conn: conn}) do
    # inflateEnd raises data_error when the stream did not end.
    result =
      try do
        :zlib.inflateEnd(zlib)
        {:done, conn}
      catch
        :error, _ -> {:error, :bad_gzip, conn}
      end

    :zlib.close(zlib)
    result
  end

  @doc "Releases a reader abandoned before the end of the body. Returns the conn."
  def close(%__MODULE__{zlib: zlib, conn: conn}) do
    if zlib, do: :zlib.close(zlib)
    conn
  end

  defp fail(%__MODULE__{zlib: zlib, conn: conn}, reason) do
    if zlib, do: :zlib.close(zlib)
    {:error, reason, conn}
  end

  @doc """
  Writes `initial` and then the rest of the body to a new file at `path`:
  `{:ok, conn}` or `{:error, reason, conn}`, removing the file on error.
  """
  def copy_to_file(%__MODULE__{} = reader, initial, path) do
    case File.open(path, [:write, :exclusive, :raw, :binary]) do
      {:ok, file} ->
        result =
          try do
            case write_result(IO.binwrite(file, initial)) do
              :ok -> copy_chunks(reader, file)
              {:error, reason} -> fail(reader, reason)
            end
          after
            File.close(file)
          end

        with {:error, _, _} <- result, do: File.rm(path)
        result

      {:error, posix} ->
        fail(reader, {:file, posix})
    end
  end

  defp copy_chunks(reader, file) do
    case next(reader) do
      {:ok, chunk, reader} ->
        case write_result(IO.binwrite(file, chunk)) do
          :ok -> copy_chunks(reader, file)
          {:error, reason} -> fail(reader, reason)
        end

      {:done, conn} ->
        {:ok, conn}

      {:error, reason, conn} ->
        {:error, reason, conn}
    end
  end

  defp write_result(:ok), do: :ok
  defp write_result({:error, posix}), do: {:error, {:file, posix}}
end
