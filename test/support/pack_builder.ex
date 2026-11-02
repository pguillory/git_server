defmodule GitServer.PackBuilder do
  @moduledoc """
  Builds packs byte by byte, including malformed ones git would never write.

  An entry is a map: `:type` (1 to 4 for whole objects, 6 for OFS_DELTA, 7 for
  REF_DELTA), `:size` (the declared size), `:data` (the bytes after the header,
  usually a zlib stream), `:id` (the id to list in an idx), and for deltas `:base`
  (an earlier entry's index for OFS_DELTA, an id for REF_DELTA).
  """

  import Bitwise

  alias GitServer.{Object, ObjectId}

  @type_codes %{commit: 1, tree: 2, blob: 3, tag: 4}

  @doc "A whole object entry."
  def object(type, content, opts \\ []) do
    level = Keyword.get(opts, :level, :default)

    %{
      type: @type_codes[type],
      size: byte_size(content),
      data: compress(content, level),
      id: Object.id(type, content),
    }
  end

  @doc "A REF_DELTA entry, listed in an idx as `id`."
  def ref_delta(id, base_id, delta),
    do: %{type: 7, size: byte_size(delta), data: :zlib.compress(delta), id: id, base: base_id}

  @doc "An OFS_DELTA entry against the entry at index `base`."
  def ofs_delta(id, base, delta),
    do: %{type: 6, size: byte_size(delta), data: :zlib.compress(delta), id: id, base: base}

  @doc "A delta that inserts `content` whole, against a base of `base_size` bytes."
  def insert_delta(base_size, content),
    do: varint(base_size) <> varint(byte_size(content)) <> inserts(content)

  defp inserts(<<chunk::binary-size(127), rest::binary>>), do: <<127>> <> chunk <> inserts(rest)
  defp inserts(<<>>), do: <<>>
  defp inserts(rest), do: <<byte_size(rest)>> <> rest

  @doc "Compresses with zlib at a level (0 stores the bytes uncompressed)."
  def compress(content, :default), do: :zlib.compress(content)

  def compress(content, level) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, level)
    out = :zlib.deflate(z, content, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    IO.iodata_to_binary(out)
  end

  @doc """
  Builds a pack from `entries`. Returns `{pack, idx_entries}`, where `idx_entries`
  is a list of `{id, offset, crc32}` for `GitServer.Pack.Idx.encode/2`. `:count`
  overrides the object count in the header.
  """
  def build(entries, opts \\ []) do
    count = Keyword.get(opts, :count, length(entries))

    {body, idx_entries, _offsets} =
      Enum.reduce(entries, {<<"PACK", 2::32, count::32>>, [], []}, fn entry,
                                                                      {body, idx, offsets} ->
        offset = byte_size(body)
        raw = header(entry, offset, Enum.reverse(offsets)) <> entry.data
        {body <> raw, [{entry.id, offset, :erlang.crc32(raw)} | idx], [offset | offsets]}
      end)

    {body <> ObjectId.hash(body), Enum.reverse(idx_entries)}
  end

  defp header(entry, offset, offsets) do
    first = bor(entry.type <<< 4, band(entry.size, 0x0F))
    size_bytes = size_rest(first, entry.size >>> 4)

    case entry.type do
      6 -> size_bytes <> ofs(offset - Enum.at(offsets, entry.base))
      7 -> size_bytes <> entry.base
      _ -> size_bytes
    end
  end

  defp size_rest(byte, 0), do: <<byte>>
  defp size_rest(byte, rest), do: <<bor(byte, 0x80)>> <> size_rest(band(rest, 0x7F), rest >>> 7)

  # The OFS_DELTA distance encoding, the inverse of the decoder's "add 1 then shift".
  def ofs(distance) do
    bytes = ofs_bytes(distance >>> 7, [band(distance, 0x7F)])
    :erlang.list_to_binary(bytes)
  end

  defp ofs_bytes(0, acc), do: acc
  defp ofs_bytes(n, acc), do: ofs_bytes((n - 1) >>> 7, [bor(0x80, band(n - 1, 0x7F)) | acc])

  def varint(n) when n < 0x80, do: <<n>>
  def varint(n), do: <<bor(0x80, band(n, 0x7F))>> <> varint(n >>> 7)
end
