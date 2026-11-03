defmodule GitServer.Pack.Idx do
  @moduledoc """
  Git's pack index, version 2: the magic `"\\xFFtOc"` and version 2, a 256-entry
  fanout table (how many ids start with a byte at most `b`), the sorted ids, a CRC-32
  of each object's raw bytes in the pack, each object's offset (4 bytes; with the high
  bit set, an index into a table of 8-byte offsets that follows), the pack's checksum
  and a SHA-1 of everything before it.

  The whole index is held as one binary and searched in place.
  """

  import Bitwise

  alias GitServer.ObjectId

  @magic <<0xFF, "tOc", 2::32>>
  @fanout_size 256 * 4
  @large_offset 0x80000000

  defstruct [:binary, :count, :pack_checksum]

  @type t :: %__MODULE__{binary: binary, count: non_neg_integer, pack_checksum: ObjectId.t()}

  @doc """
  Encodes an index for `entries`, a list of `{id, offset, crc32}`, in any order.
  """
  @spec encode([{ObjectId.t(), non_neg_integer, non_neg_integer}], ObjectId.t()) :: binary
  def encode(entries, pack_checksum) do
    entries = Enum.sort(entries)
    counts = Enum.frequencies_by(entries, fn {<<first, _::binary>>, _, _} -> first end)

    {fanout, _} =
      Enum.map_reduce(0..255, 0, fn byte, total ->
        total = total + Map.get(counts, byte, 0)
        {<<total::32>>, total}
      end)

    {offsets, {large, _}} =
      Enum.map_reduce(entries, {[], 0}, fn {_, offset, _}, {large, n} ->
        if offset < @large_offset,
          do: {<<offset::32>>, {large, n}},
          else: {<<bor(@large_offset, n)::32>>, {[<<offset::64>> | large], n + 1}}
      end)

    body =
      IO.iodata_to_binary([
        @magic,
        fanout,
        Enum.map(entries, fn {id, _, _} -> id end),
        Enum.map(entries, fn {_, _, crc} -> <<crc::32>> end),
        offsets,
        Enum.reverse(large),
        pack_checksum,
      ])

    body <> ObjectId.hash(body)
  end

  @doc """
  Decodes and checks an index: its header, sizes, fanout order and checksum.
  """
  @spec decode(binary) :: {:ok, t} | {:error, String.t()}
  def decode(<<@magic, fanout::binary-size(@fanout_size), _::binary>> = binary) do
    id_size = ObjectId.size()
    count = :binary.decode_unsigned(binary_part(fanout, @fanout_size - 4, 4))
    small_end = byte_size(@magic) + @fanout_size + count * (id_size + 8)
    trailer = 2 * id_size
    large_bytes = byte_size(binary) - small_end - trailer

    cond do
      large_bytes < 0 or rem(large_bytes, 8) != 0 ->
        {:error, "bad pack index size"}

      not sorted?(fanout) ->
        {:error, "bad pack index fanout"}

      not large_offsets_valid?(binary, small_end - count * 4, count, div(large_bytes, 8)) ->
        {:error, "bad pack index offset"}

      ObjectId.hash(binary_part(binary, 0, byte_size(binary) - id_size)) !=
          binary_part(binary, byte_size(binary) - id_size, id_size) ->
        {:error, "pack index checksum mismatch"}

      true ->
        pack_checksum = binary_part(binary, byte_size(binary) - trailer, id_size)
        {:ok, %__MODULE__{binary: binary, count: count, pack_checksum: pack_checksum}}
    end
  end

  def decode(_) do
    {:error, "not a version 2 pack index"}
  end

  defp large_offsets_valid?(binary, start, count, large_count) do
    offsets = binary_part(binary, start, count * 4)
    Enum.all?(for <<o::32 <- offsets>>, o >= @large_offset, do: o - @large_offset < large_count)
  end

  defp sorted?(fanout) do
    counts = for <<n::32 <- fanout>>, do: n
    counts |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a <= b end)
  end

  @doc """
  The most objects an index of `bytes` bytes can list: the header, fanout and two
  checksums are fixed, and each object takes 28 bytes (plus 8 for an offset past
  2 GB, which only makes this an overestimate).
  """
  def max_count(bytes) do
    fixed = byte_size(@magic) + @fanout_size + 2 * ObjectId.size()
    div(max(bytes - fixed, 0), ObjectId.size() + 8)
  end

  @doc "The pack offset of `id`, or `:error` if the pack doesn't hold it."
  @spec offset(t, ObjectId.t()) :: {:ok, non_neg_integer} | :error
  def offset(%__MODULE__{} = idx, <<first, _::binary>> = id) do
    low = if first == 0, do: 0, else: fanout(idx, first - 1)

    case search(idx, id, low, fanout(idx, first) - 1) do
      nil -> :error
      i -> {:ok, offset_at(idx, i)}
    end
  end

  @doc "Whether the pack holds `id`."
  def member?(idx, id) do
    offset(idx, id) != :error
  end

  @doc "Every `{id, offset}` in the index, in id order."
  @spec entries(t) :: [{ObjectId.t(), non_neg_integer}]
  def entries(%__MODULE__{count: count} = idx) do
    for i <- 0..(count - 1)//1, do: {id_at(idx, i), offset_at(idx, i)}
  end

  @doc "The CRC-32 recorded for the `i`th id."
  def crc_at(%__MODULE__{binary: binary, count: count}, i) do
    start = byte_size(@magic) + @fanout_size + count * ObjectId.size() + i * 4
    <<crc::32>> = binary_part(binary, start, 4)
    crc
  end

  defp fanout(%__MODULE__{binary: binary}, byte) do
    <<n::32>> = binary_part(binary, byte_size(@magic) + byte * 4, 4)
    n
  end

  defp search(_idx, _id, low, high) when low > high do
    nil
  end

  defp search(idx, id, low, high) do
    mid = div(low + high, 2)

    case id_at(idx, mid) do
      ^id -> mid
      other when other < id -> search(idx, id, mid + 1, high)
      _ -> search(idx, id, low, mid - 1)
    end
  end

  defp id_at(%__MODULE__{binary: binary}, i) do
    size = ObjectId.size()
    binary_part(binary, byte_size(@magic) + @fanout_size + i * size, size)
  end

  defp offset_at(%__MODULE__{binary: binary, count: count}, i) do
    small = byte_size(@magic) + @fanout_size + count * (ObjectId.size() + 4)
    <<offset::32>> = binary_part(binary, small + i * 4, 4)

    if offset < @large_offset do
      offset
    else
      large = small + count * 4 + band(offset, @large_offset - 1) * 8
      <<offset::64>> = binary_part(binary, large, 8)
      offset
    end
  end
end
