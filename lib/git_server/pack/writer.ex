defmodule GitServer.Pack.Writer do
  @moduledoc """
  Writes a pack of whole objects (no deltas), streamed out in pieces.

  Each piece of the pack goes to `emit.(iodata, acc)`, which returns the new `acc`:
  the header first, then one piece per object (its header and zlib stream), then the
  trailer checksum. A pack without deltas is valid and every git client accepts it.
  """

  alias GitServer.{ObjectDB, ObjectId, Pack}

  @doc """
  Writes the objects `ids`, read from `db`, in order. Returns `{:ok, checksum, acc}`,
  or `{:error, reason, acc}` if an object can't be read, in which case the pack
  emitted so far is incomplete and the caller must report the failure instead.
  """
  @spec write(ObjectDB.t(), [ObjectId.t()], acc, (iodata, acc -> acc)) ::
          {:ok, ObjectId.t(), acc} | {:error, String.t(), acc}
        when acc: term
  def write(db, ids, acc, emit) do
    header = Pack.encode_header(length(ids))
    state = {ObjectId.hash_update(ObjectId.hash_init(), header), emit.(header, acc)}

    result =
      Enum.reduce_while(ids, {:ok, state}, fn id, {:ok, {hash, acc}} ->
        case ObjectDB.read(db, id) do
          {:ok, type, content} ->
            piece = [Pack.encode_object_header(type, byte_size(content)), :zlib.compress(content)]
            {:cont, {:ok, {ObjectId.hash_update(hash, piece), emit.(piece, acc)}}}

          :error ->
            {:halt, {:error, "missing object #{ObjectId.to_hex(id)}", acc}}

          {:error, reason} ->
            {:halt, {:error, reason, acc}}
        end
      end)

    case result do
      {:ok, {hash, acc}} ->
        checksum = ObjectId.hash_final(hash)
        {:ok, checksum, emit.(checksum, acc)}

      error ->
        error
    end
  end
end
