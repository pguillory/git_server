defmodule GitServer.Pack do
  @moduledoc """
  Git's pack format: the file header, per-object headers and the trailer.

  A pack is `"PACK"`, a version (2 or 3) and an object count, each 4 bytes big-endian,
  then the objects, then the SHA-1 of everything before it. Each object starts with a
  header giving its type and inflated size, then for a delta the base (a backwards
  offset for OFS_DELTA, an object id for REF_DELTA), then a zlib stream.
  """

  import Bitwise

  alias GitServer.ObjectId

  @header_size 12

  @typedoc """
  What an object entry holds: a whole object of a type, or a delta against a base
  given by its pack offset or its id.
  """
  @type kind ::
          {:base, GitServer.Object.type()} | {:ofs, non_neg_integer} | {:ref, ObjectId.t()}

  @doc "The size of the pack file header."
  def header_size, do: @header_size

  @doc "The size of the trailer checksum."
  def trailer_size, do: ObjectId.size()

  @doc "Encodes the pack file header."
  def encode_header(count), do: <<"PACK", 2::32, count::32>>

  @doc "Parses the pack file header."
  def parse_header(<<"PACK", version::32, count::32, _::binary>>) when version in [2, 3],
    do: {:ok, count}

  def parse_header(_), do: {:error, "not a pack file"}

  @doc "Encodes an object header for a whole object."
  def encode_object_header(type, size), do: encode_size(type_code(type), size)

  @doc """
  Encodes the header of an OFS_DELTA entry: its delta's inflated `size`, and its
  base `distance` bytes before the entry's own offset.
  """
  def encode_ofs_delta_header(size, distance) when distance > 0,
    do: encode_size(6, size) <> encode_ofs_distance(distance)

  defp encode_size(code, size) do
    first = bor(code <<< 4, band(size, 0x0F))
    encode_size_rest(first, size >>> 4)
  end

  defp encode_size_rest(byte, 0), do: <<byte>>

  defp encode_size_rest(byte, rest),
    do: <<bor(byte, 0x80)>> <> encode_size_rest(band(rest, 0x7F), rest >>> 7)

  @doc """
  Parses the object header at the start of `binary`, for an object at pack offset
  `offset`. Returns the kind, the inflated size (of the object, or for a delta of its
  instruction stream) and the header's length, or `:more` when `binary` is too short.
  """
  @spec parse_object_header(binary, non_neg_integer) ::
          {:ok, kind, non_neg_integer, pos_integer} | :more | {:error, String.t()}
  def parse_object_header(<<byte, rest::binary>>, offset) do
    type_code = band(byte >>> 4, 7)
    size = band(byte, 0x0F)

    with {:ok, size, rest, used} <- size_varint(byte, rest, size, 4, 1),
         {:ok, kind, used} <- kind(type_code, rest, offset, used) do
      {:ok, kind, size, used}
    end
  end

  def parse_object_header(<<>>, _offset), do: :more

  # A size never needs more than 64 bits; a longer varint is corrupt.
  defp size_varint(byte, _rest, _size, shift, _used) when byte >= 0x80 and shift > 60,
    do: {:error, "bad object header"}

  defp size_varint(byte, <<next, rest::binary>>, size, shift, used) when byte >= 0x80,
    do: size_varint(next, rest, bor(size, band(next, 0x7F) <<< shift), shift + 7, used + 1)

  defp size_varint(byte, <<>>, _size, _shift, _used) when byte >= 0x80, do: :more
  defp size_varint(_byte, rest, size, _shift, used), do: {:ok, size, rest, used}

  defp kind(1, _rest, _offset, used), do: {:ok, {:base, :commit}, used}
  defp kind(2, _rest, _offset, used), do: {:ok, {:base, :tree}, used}
  defp kind(3, _rest, _offset, used), do: {:ok, {:base, :blob}, used}
  defp kind(4, _rest, _offset, used), do: {:ok, {:base, :tag}, used}

  defp kind(6, rest, offset, used) do
    with {:ok, distance, n} <- ofs_varint(rest, 0, 0) do
      if distance > 0 and distance <= offset - @header_size do
        {:ok, {:ofs, offset - distance}, used + n}
      else
        {:error, "bad delta base offset"}
      end
    end
  end

  defp kind(7, rest, _offset, used) do
    id_size = ObjectId.size()

    case rest do
      <<id::binary-size(id_size), _::binary>> -> {:ok, {:ref, id}, used + id_size}
      _ -> :more
    end
  end

  defp kind(_, _rest, _offset, _used), do: {:error, "bad object type"}

  # OFS_DELTA distance: big-endian 7-bit groups, adding 1 before each shift.
  defp ofs_varint(_rest, _value, n) when n > 9, do: {:error, "bad delta base offset"}
  defp ofs_varint(<<>>, _value, _n), do: :more

  defp ofs_varint(<<byte, rest::binary>>, value, n) do
    value = if n == 0, do: band(byte, 0x7F), else: bor((value + 1) <<< 7, band(byte, 0x7F))
    if byte >= 0x80, do: ofs_varint(rest, value, n + 1), else: {:ok, value, n + 1}
  end

  # The inverse of `ofs_varint/3`: big-endian 7-bit groups, subtracting 1 before
  # each shift.
  defp encode_ofs_distance(distance) do
    :erlang.list_to_binary(ofs_bytes(distance >>> 7, [band(distance, 0x7F)]))
  end

  defp ofs_bytes(0, acc), do: acc
  defp ofs_bytes(n, acc), do: ofs_bytes((n - 1) >>> 7, [bor(0x80, band(n - 1, 0x7F)) | acc])

  defp type_code(:commit), do: 1
  defp type_code(:tree), do: 2
  defp type_code(:blob), do: 3
  defp type_code(:tag), do: 4
end
