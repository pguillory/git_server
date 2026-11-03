defmodule GitServer.Pack.Writer do
  @moduledoc """
  Writes a pack of whole objects (no deltas), streamed out in pieces.

  Each piece of the pack goes to `emit.(iodata, acc)`, which returns `{:ok, acc}`:
  the header first, then one piece per object (its header and zlib stream), then the
  trailer checksum. A pack without deltas is valid and every git client accepts it.
  """

  alias GitServer.ObjectDB
  alias GitServer.ObjectId
  alias GitServer.Pack

  @doc """
  Writes the objects `ids`, read from `db`, in order. `emit.(iodata, acc)` returns
  `{:ok, acc}`, or `{:error, reason, acc}` to stop. Returns `{:ok, checksum, acc}`, or
  `{:error, reason, acc}` if `emit` stopped or an object can't be read, in which case
  the pack emitted so far is incomplete and the caller must report the failure instead.
  """
  @spec write(ObjectDB.t(), [ObjectId.t()], acc, (iodata, acc -> {:ok, acc} | error)) ::
          {:ok, ObjectId.t(), acc} | error
        when acc: term, error: {:error, term, acc}
  def write(db, ids, acc, emit) do
    header = Pack.encode_header(length(ids))

    with {:ok, acc} <- emit.(header, acc),
         {:ok, hash, acc} <-
           write_objects(db, ids, ObjectId.hash_update(ObjectId.hash_init(), header), acc, emit) do
      checksum = ObjectId.hash_final(hash)

      with {:ok, acc} <- emit.(checksum, acc) do
        {:ok, checksum, acc}
      end
    end
  end

  defp write_objects(_db, [], hash, acc, _emit) do
    {:ok, hash, acc}
  end

  defp write_objects(db, [id | ids], hash, acc, emit) do
    case ObjectDB.read(db, id) do
      {:ok, type, content} ->
        piece = [Pack.encode_object_header(type, byte_size(content)), :zlib.compress(content)]

        with {:ok, acc} <- emit.(piece, acc) do
          write_objects(db, ids, ObjectId.hash_update(hash, piece), acc, emit)
        end

      :error ->
        {:error, "missing object #{ObjectId.to_hex(id)}", acc}

      {:error, reason} ->
        {:error, reason, acc}
    end
  end
end
