defmodule GitServer.PktLineTest do
  use ExUnit.Case, async: true
  import GitServer.PktLine

  test "encode and decode" do
    assert IO.iodata_to_binary(encode("hi\n")) == "0007hi\n"
    assert IO.iodata_to_binary(encode(String.duplicate("a", 65_516))) =~ ~r/\Afff0a/
    assert_raise ArgumentError, fn -> encode("") end
    assert_raise ArgumentError, fn -> encode(String.duplicate("a", 65_517)) end

    assert decode("0007hi\n000000010002") ==
             {:ok, ["hi\n", :flush, :delim, :response_end]}

    assert decode_one("0007hi\nrest") == {:ok, "hi\n", "rest"}
    assert decode_one("0007hi") == :incomplete
    assert decode_one("00") == :incomplete
    assert decode_one("0003") == {:error, "invalid pkt-line length"}

    assert decode_one("fff1" <> String.duplicate("a", 65_520)) ==
             {:error, "pkt-line too long"}

    assert decode("0007hi") == {:error, "truncated pkt-line"}
    assert decode("+007hi\n") == {:error, "invalid pkt-line length"}
    assert chomp("a\n") == "a"
    assert chomp("a") == "a"
    assert chomp("") == ""
    assert decode("0004") == {:ok, [""]}
    long = error(String.duplicate("x", 70_000)) |> IO.iodata_to_binary()
    assert {:ok, ["ERR xxx" <> _ = message]} = decode(long)
    assert byte_size(message) == 65_516
  end

  test "side-band packets are at most 65520 bytes" do
    assert sideband(1, "") == []
    assert sideband(2, "progress") |> IO.iodata_to_binary() == "000d\x02progress"

    data = :crypto.strong_rand_bytes(65_515 * 2 + 1)

    {:ok, packets} =
      data |> then(&sideband(1, &1)) |> IO.iodata_to_binary() |> decode()

    assert Enum.map(packets, &byte_size/1) == [65_516, 65_516, 2]
    assert Enum.map_join(packets, fn <<1, chunk::binary>> -> chunk end) == data
  end
end
