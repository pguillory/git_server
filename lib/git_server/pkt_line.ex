defmodule GitServer.PktLine do
  @moduledoc """
  Git's pkt-line framing (gitprotocol-common): a 4-digit hex length that counts
  itself, then the data, at most 65516 data bytes per packet. Three special packets
  carry no data: flush `0000`, delim `0001` and response-end `0002`. Never send
  `0002` on the HTTP wire: git's remote-curl inserts it into its own stream.

  Also side-band framing: in a side-band stream each packet's data starts with a
  band byte, 1 for data, 2 for progress text, 3 for a fatal error, and the whole
  packet is at most 65520 bytes.
  """

  @max_data 65_516
  @max_band_data @max_data - 1

  @doc "The largest data a single packet can carry."
  def max_data do
    @max_data
  end

  @doc "Encodes one data packet. Raises for empty or oversized data."
  def encode(data) do
    size = IO.iodata_length(data)

    if size == 0 or size > @max_data do
      raise ArgumentError, "a pkt-line holds 1 to #{@max_data} bytes, not #{size}"
    end

    [hex_length(size + 4), data]
  end

  def flush do
    "0000"
  end

  def delim do
    "0001"
  end

  def response_end do
    "0002"
  end

  @doc """
  An `ERR <message>` packet, which git shows as a remote error. A message too long
  for one packet (it may quote the client) is cut to fit.
  """
  def error(message) do
    text = "ERR " <> message
    encode(binary_part(text, 0, min(byte_size(text), @max_data - 1)) <> "\n")
  end

  @doc """
  Encodes `data` on side-band `band` (1, 2 or 3), split across as many packets as
  it needs. Empty data encodes to nothing.
  """
  def sideband(band, data) when band in 1..3 do
    data |> IO.iodata_to_binary() |> sideband_chunks(band)
  end

  defp sideband_chunks(<<>>, _band) do
    []
  end

  defp sideband_chunks(data, band) do
    size = min(byte_size(data), @max_band_data)
    <<chunk::binary-size(size), rest::binary>> = data
    [encode([band, chunk]) | sideband_chunks(rest, band)]
  end

  @doc """
  Decodes the first packet of `binary`: `{:ok, packet, rest}`, `:incomplete` when
  more bytes are needed, or `{:error, reason}` for a malformed length.
  """
  def decode_one(<<"0000", rest::binary>>) do
    {:ok, :flush, rest}
  end

  def decode_one(<<"0001", rest::binary>>) do
    {:ok, :delim, rest}
  end

  def decode_one(<<"0002", rest::binary>>) do
    {:ok, :response_end, rest}
  end

  def decode_one(<<hex::binary-size(4), rest::binary>>) do
    case parse_length(hex) do
      {:ok, length} when length < 4 ->
        {:error, "invalid pkt-line length"}

      {:ok, length} when length - 4 > @max_data ->
        {:error, "pkt-line too long"}

      {:ok, length} ->
        case rest do
          <<data::binary-size(length - 4), rest::binary>> -> {:ok, data, rest}
          _ -> :incomplete
        end

      :error ->
        {:error, "invalid pkt-line length"}
    end
  end

  def decode_one(_short) do
    :incomplete
  end

  @doc """
  Decodes a whole binary into packets: `{:ok, packets}`, or `{:error, reason}` when
  it is malformed or ends inside a packet.
  """
  def decode(binary) do
    decode_all(binary, [])
  end

  defp decode_all(<<>>, packets) do
    {:ok, Enum.reverse(packets)}
  end

  defp decode_all(binary, packets) do
    case decode_one(binary) do
      {:ok, packet, rest} -> decode_all(rest, [packet | packets])
      :incomplete -> {:error, "truncated pkt-line"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Drops one trailing newline from a data packet, as git's readers do."
  def chomp(data) when is_binary(data) do
    String.replace_suffix(data, "\n", "")
  end

  defp parse_length(hex) do
    if hex =~ ~r/\A[0-9a-fA-F]{4}\z/ do
      {:ok, String.to_integer(hex, 16)}
    else
      :error
    end
  end

  defp hex_length(length) do
    length |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
  end
end
