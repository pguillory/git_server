defmodule GitServer.PktLineTest do
  use ExUnit.Case, async: true
  alias GitServer.PktLine

  test "encode and decode" do
    assert IO.iodata_to_binary(PktLine.encode("hi\n")) == "0007hi\n"
    assert IO.iodata_to_binary(PktLine.encode(String.duplicate("a", 65_516))) =~ ~r/\Afff0a/
    assert_raise ArgumentError, fn -> PktLine.encode("") end
    assert_raise ArgumentError, fn -> PktLine.encode(String.duplicate("a", 65_517)) end

    assert PktLine.decode("0007hi\n000000010002") ==
             {:ok, ["hi\n", :flush, :delim, :response_end]}

    assert PktLine.decode_one("0007hi\nrest") == {:ok, "hi\n", "rest"}
    assert PktLine.decode_one("0007hi") == :incomplete
    assert PktLine.decode_one("00") == :incomplete
    assert PktLine.decode_one("0003") == {:error, "invalid pkt-line length"}

    assert PktLine.decode_one("fff1" <> String.duplicate("a", 65_520)) ==
             {:error, "pkt-line too long"}

    assert PktLine.decode("0007hi") == {:error, "truncated pkt-line"}
    assert PktLine.decode("+007hi\n") == {:error, "invalid pkt-line length"}
    assert PktLine.chomp("a\n") == "a"
    assert PktLine.chomp("a") == "a"
    assert PktLine.chomp("") == ""
    assert PktLine.decode("0004") == {:ok, [""]}
    long = PktLine.error(String.duplicate("x", 70_000)) |> IO.iodata_to_binary()
    assert {:ok, ["ERR xxx" <> _ = message]} = PktLine.decode(long)
    assert byte_size(message) == 65_516
  end

  test "side-band packets are at most 65520 bytes" do
    assert PktLine.sideband(1, "") == []
    assert PktLine.sideband(2, "progress") |> IO.iodata_to_binary() == "000d\x02progress"

    data = :crypto.strong_rand_bytes(65_515 * 2 + 1)

    {:ok, packets} =
      data |> then(&PktLine.sideband(1, &1)) |> IO.iodata_to_binary() |> PktLine.decode()

    assert Enum.map(packets, &byte_size/1) == [65_516, 65_516, 2]
    assert Enum.map_join(packets, fn <<1, chunk::binary>> -> chunk end) == data
  end
end
