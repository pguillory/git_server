defmodule GitServer.Pack.Delta do
  @moduledoc """
  Git's delta format: the base size and result size as little-endian varints, then
  instructions. An instruction byte with the high bit set copies a range of the base
  (its low 4 bits say which offset bytes follow, the next 3 which size bytes; a size
  of 0 means 0x10000). Otherwise the byte is a count of literal bytes that follow to
  insert. A zero byte is reserved and invalid.
  """

  import Bitwise

  @doc """
  The base size and result size a delta declares, from its first bytes, and the
  instructions that follow them.
  """
  @spec sizes(binary) :: {:ok, non_neg_integer, non_neg_integer, binary} | {:error, String.t()}
  def sizes(delta) do
    with {:ok, base_size, rest} <- varint(delta, 0, 0),
         {:ok, result_size, rest} <- varint(rest, 0, 0) do
      {:ok, base_size, result_size, rest}
    end
  end

  @doc """
  Applies `delta` to `base`. Fails if the declared base size isn't the base's size,
  the declared result size is over `max_size`, an instruction is malformed or reads
  outside the base, or the result isn't exactly the declared size.
  """
  @spec apply(binary, binary, non_neg_integer) :: {:ok, binary} | {:error, String.t()}
  def apply(base, delta, max_size) do
    with {:ok, base_size, result_size, instructions} <- sizes(delta) do
      cond do
        base_size != byte_size(base) -> {:error, "delta base size mismatch"}
        result_size > max_size -> {:error, "object too large"}
        true -> run(instructions, base, result_size, <<>>)
      end
    end
  end

  defp varint(_binary, _value, shift) when shift > 63, do: {:error, "bad delta header"}
  defp varint(<<>>, _value, _shift), do: {:error, "bad delta header"}

  defp varint(<<byte, rest::binary>>, value, shift) do
    value = bor(value, band(byte, 0x7F) <<< shift)
    if byte >= 0x80, do: varint(rest, value, shift + 7), else: {:ok, value, rest}
  end

  # The result grows by appending to one binary, which the VM does in place, so a
  # delta of many tiny instructions costs no more memory than its result.
  defp run(<<>>, _base, size, acc) when byte_size(acc) == size, do: {:ok, acc}
  defp run(<<>>, _base, _size, _acc), do: {:error, "delta result size mismatch"}
  defp run(<<0, _::binary>>, _base, _size, _acc), do: {:error, "bad delta instruction"}

  defp run(<<cmd, rest::binary>>, base, size, acc) when cmd >= 0x80 do
    with {:ok, offset, rest} <- copy_arg(cmd, rest, 0, 0, 4),
         {:ok, length, rest} <- copy_arg(cmd >>> 4, rest, 0, 0, 3) do
      length = if length == 0, do: 0x10000, else: length

      cond do
        offset + length > byte_size(base) -> {:error, "bad delta copy"}
        byte_size(acc) + length > size -> {:error, "delta result size mismatch"}
        true -> run(rest, base, size, acc <> binary_part(base, offset, length))
      end
    end
  end

  defp run(<<count, rest::binary>>, base, size, acc) do
    case rest do
      _ when byte_size(acc) + count > size ->
        {:error, "delta result size mismatch"}

      <<literal::binary-size(count), rest::binary>> ->
        run(rest, base, size, acc <> literal)

      _ ->
        {:error, "bad delta instruction"}
    end
  end

  # Little-endian bytes, present when the matching bit of `bits` is set.
  defp copy_arg(_bits, rest, value, i, i), do: {:ok, value, rest}

  defp copy_arg(bits, rest, value, i, n) do
    if band(bits, 1 <<< i) == 0 do
      copy_arg(bits, rest, value, i + 1, n)
    else
      case rest do
        <<byte, rest::binary>> -> copy_arg(bits, rest, bor(value, byte <<< (8 * i)), i + 1, n)
        <<>> -> {:error, "bad delta instruction"}
      end
    end
  end
end
