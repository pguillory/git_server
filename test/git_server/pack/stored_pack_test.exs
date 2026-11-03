defmodule GitServer.Pack.StoredPackTest do
  use ExUnit.Case, async: true

  import GitServer.PackBuilder

  alias GitServer.ObjectDB
  alias GitServer.ObjectId
  alias GitServer.Pack
  alias GitServer.Pack.Delta
  alias GitServer.Pack.Idx

  @moduletag :tmp_dir

  defp open(dir, entries, opts \\ []) do
    {pack, idx_entries} = build(entries)
    pack_path = Path.join(dir, "test.pack")
    idx_path = Path.join(dir, "test.idx")
    File.write!(pack_path, pack)
    File.write!(idx_path, Idx.encode(idx_entries, binary_part(pack, byte_size(pack) - 20, 20)))
    ObjectDB.open([{pack_path, idx_path}], opts)
  end

  test "resolves deltas against whole objects and other deltas", %{tmp_dir: dir} do
    base = object(:blob, "hello")
    id1 = GitServer.Object.id(:blob, "hello world")
    id2 = GitServer.Object.id(:blob, "brand new")
    copy = varint(5) <> varint(11) <> <<0x90, 5>> <> <<6, " world">>

    {:ok, db} =
      open(dir, [
        base,
        ofs_delta(id1, 0, copy),
        ref_delta(id2, id1, insert_delta(11, "brand new")),
      ])

    assert ObjectDB.read(db, id1) == {:ok, :blob, "hello world"}
    assert ObjectDB.lookup(db, id2) == {:ok, :blob, 9}
    assert ObjectDB.read(db, id2) == {:ok, :blob, "brand new"}
  end

  test "the base work budget charges bases resolved for little output", %{tmp_dir: dir} do
    big = String.duplicate("a", 10_000)
    id = GitServer.Object.id(:blob, "tiny")
    entries = [object(:blob, big), ofs_delta(id, 0, insert_delta(10_000, "tiny"))]

    # With no cache, every read of the 4-byte delta inflates its 10,000-byte base again,
    # and earns only 4 bytes of allowance.
    opts = [max_base_work_bytes: 25_000, cache_bytes: 0, max_delta_depth: 1]
    {:ok, db} = open(dir, entries, opts)
    assert ObjectDB.read(db, id) == {:ok, :blob, "tiny"}
    assert ObjectDB.read(db, id) == {:ok, :blob, "tiny"}
    assert ObjectDB.read(db, id) == {:error, "too much work resolving delta bases"}
  end

  test "a long chain of same-size versions, read in full, stays within any floor",
       %{tmp_dir: dir} do
    [first | rest] = for n <- 0..20, do: String.duplicate(<<?a + n>>, 1000)

    # Each version a delta of the one before, as git stores a file's history.
    entries =
      [object(:blob, first)] ++
        for {content, n} <- Enum.with_index(rest),
            do: ofs_delta(GitServer.Object.id(:blob, content), n, insert_delta(1000, content))

    {:ok, db} = open(dir, entries, max_base_work_bytes: 1, cache_bytes: 0, max_delta_depth: 20)

    # The deepest first, the costliest order.
    for content <- Enum.reverse([first | rest]) do
      assert ObjectDB.read(db, GitServer.Object.id(:blob, content)) == {:ok, :blob, content}
    end
  end

  test "a REF_DELTA whose base isn't in the pack", %{tmp_dir: dir} do
    id = :binary.copy(<<1>>, 20)
    {:ok, db} = open(dir, [ref_delta(id, :binary.copy(<<2>>, 20), insert_delta(1, "a"))])
    assert ObjectDB.member?(db, id)
    refute ObjectDB.member?(db, ObjectId.zero())
    assert ObjectDB.read(db, id) == {:error, "missing delta base"}

    assert {:error, "missing delta base", _} =
             GitServer.Pack.Writer.write(db, [id], [], fn piece, acc -> [acc | piece] end)
  end

  test "the depth limit holds when part of a chain is cached", %{tmp_dir: dir} do
    d1 = :binary.copy(<<1>>, 20)
    d2 = :binary.copy(<<2>>, 20)

    entries = [
      object(:blob, "a"),
      ofs_delta(d1, 0, insert_delta(1, "b")),
      ofs_delta(d2, 1, insert_delta(1, "c")),
    ]

    {:ok, db} = open(dir, entries, max_delta_depth: 1)
    assert ObjectDB.read(db, d1) == {:ok, :blob, "b"}
    assert ObjectDB.read(db, d2) == {:error, "delta chain too deep"}
    {:ok, db} = open(dir, entries, max_delta_depth: 2)
    assert ObjectDB.read(db, d2) == {:ok, :blob, "c"}
  end

  test "a cycle of REF_DELTAs fails instead of looping", %{tmp_dir: dir} do
    a = :binary.copy(<<0xA>>, 20)
    b = :binary.copy(<<0xB>>, 20)

    {:ok, db} =
      open(dir, [ref_delta(a, b, insert_delta(1, "a")), ref_delta(b, a, insert_delta(1, "b"))])

    assert ObjectDB.read(db, a) == {:error, "delta chain too deep"}
    assert ObjectDB.lookup(db, b) == {:error, "delta chain too deep"}
  end

  test "a delta whose declared result is over the cap", %{tmp_dir: dir} do
    id = :binary.copy(<<1>>, 20)
    big = varint(5) <> varint(2_000) <> <<0x90, 5>>

    {:ok, db} =
      open(dir, [object(:blob, "hello"), ofs_delta(id, 0, big)], max_object_bytes: 1_000)

    assert ObjectDB.read(db, id) == {:error, "object too large"}
    assert ObjectDB.lookup(db, id) == {:error, "object too large"}
  end

  test "a corrupt zlib stream or a wrong declared size", %{tmp_dir: dir} do
    garbage = %{object(:blob, "hello") | data: "not zlib at all"}
    short = %{object(:blob, "hello") | size: 9, id: :binary.copy(<<2>>, 20)}
    long = %{object(:blob, "hello") | size: 3, id: :binary.copy(<<3>>, 20)}
    {:ok, db} = open(dir, [garbage, short, long])
    assert ObjectDB.read(db, garbage.id) == {:error, "corrupt object"}
    assert ObjectDB.read(db, short.id) == {:error, "object size mismatch"}
    assert ObjectDB.read(db, long.id) == {:error, "object size mismatch"}
  end

  test "a zlib stream that asks for a preset dictionary", %{tmp_dir: dir} do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z)
    _ = :zlib.deflateSetDictionary(z, "dictionary")
    data = IO.iodata_to_binary(:zlib.deflate(z, "hello", :finish))
    :zlib.close(z)
    plain = %{object(:blob, "hello") | data: data}
    id = :binary.copy(<<5>>, 20)
    delta = %{ofs_delta(id, 0, "") | data: data, size: 5}
    {:ok, db} = open(dir, [plain, delta])
    assert ObjectDB.read(db, plain.id) == {:error, "corrupt object"}
    assert ObjectDB.lookup(db, id) == {:error, "corrupt object"}
  end

  test "an empty pack", %{tmp_dir: dir} do
    {:ok, db} = open(dir, [])
    assert ObjectDB.read(db, ObjectId.zero()) == :error
    ObjectDB.close(db)
  end

  test "an idx whose offsets don't fit its pack", %{tmp_dir: dir} do
    one = object(:blob, "one")
    two = object(:blob, "two")
    {pack, [{_, o1, c1}, {_, _o2, c2}]} = build([one, two])
    checksum = binary_part(pack, byte_size(pack) - 20, 20)
    File.write!(Path.join(dir, "p.pack"), pack)

    for entries <- [
          [{one.id, o1, c1}, {two.id, o1, c2}],
          [{one.id, o1, c1}, {two.id, byte_size(pack), c2}],
        ] do
      File.write!(Path.join(dir, "p.idx"), Idx.encode(entries, checksum))

      assert ObjectDB.open([{Path.join(dir, "p.pack"), Path.join(dir, "p.idx")}]) ==
               {:error, "pack index doesn't match pack"}
    end
  end

  test "a truncated zlib stream", %{tmp_dir: dir} do
    whole = object(:blob, String.duplicate("abc", 1000))
    cut = %{whole | data: binary_part(whole.data, 0, byte_size(whole.data) - 4)}
    {:ok, db} = open(dir, [cut])
    assert ObjectDB.read(db, cut.id) == {:error, "corrupt object"}
  end

  test "object headers" do
    assert Pack.parse_object_header(<<0x35>>, 12) == {:ok, {:base, :blob}, 5, 1}
    assert Pack.parse_object_header(<<0xB5, 0x01>>, 12) == {:ok, {:base, :blob}, 21, 2}
    assert Pack.parse_object_header(<<0xB5>>, 12) == :more
    assert Pack.parse_object_header(<<0x55>>, 12) == {:error, "bad object type"}
    assert Pack.parse_object_header(<<0x05>>, 12) == {:error, "bad object type"}
    # OFS_DELTA distances: zero, and further back than the first object.
    assert Pack.parse_object_header(<<0x65, 0>>, 100) == {:error, "bad delta base offset"}
    assert Pack.parse_object_header(<<0x65>> <> ofs(89), 100) == {:error, "bad delta base offset"}
    assert Pack.parse_object_header(<<0x65>> <> ofs(88), 100) == {:ok, {:ofs, 12}, 5, 2}
    assert Pack.parse_object_header(<<0x65>> <> ofs(300), 1000) == {:ok, {:ofs, 700}, 5, 3}

    assert Pack.parse_object_header(<<0xF5>> <> :binary.copy(<<0xFF>>, 20), 12) ==
             {:error, "bad object header"}

    id = :binary.copy(<<7>>, 20)
    assert Pack.parse_object_header(<<0x75>> <> id, 12) == {:ok, {:ref, id}, 5, 21}
    assert Pack.parse_object_header(<<0x75, 1, 2>>, 12) == :more

    for type <- [:commit, :tree, :blob, :tag], size <- [0, 15, 16, 1_000_000] do
      header = Pack.encode_object_header(type, size)
      assert Pack.parse_object_header(header, 12) == {:ok, {:base, type}, size, byte_size(header)}
    end
  end

  test "delta application" do
    base = "0123456789"
    assert Delta.apply(base, varint(10) <> varint(4) <> <<0x91, 2, 4>>, 100) == {:ok, "2345"}
    assert Delta.apply(base, varint(10) <> varint(3) <> <<3, "abc">>, 100) == {:ok, "abc"}

    assert Delta.apply(base, varint(9) <> varint(3) <> <<3, "abc">>, 100) ==
             {:error, "delta base size mismatch"}

    assert Delta.apply(base, varint(10) <> varint(300) <> <<3, "abc">>, 100) ==
             {:error, "object too large"}

    assert Delta.apply(base, varint(10) <> varint(4) <> <<3, "abc">>, 100) ==
             {:error, "delta result size mismatch"}

    assert Delta.apply(base, varint(10) <> varint(2) <> <<3, "abc">>, 100) ==
             {:error, "delta result size mismatch"}

    assert Delta.apply(base, varint(10) <> varint(3) <> <<0, "abc">>, 100) ==
             {:error, "bad delta instruction"}

    assert Delta.apply(base, varint(10) <> varint(5) <> <<5, "abc">>, 100) ==
             {:error, "bad delta instruction"}

    assert Delta.apply(base, varint(10) <> varint(4) <> <<0x91, 8, 4>>, 100) ==
             {:error, "bad delta copy"}

    assert Delta.apply(base, varint(10) <> varint(4) <> <<0x91, 8>>, 100) ==
             {:error, "bad delta instruction"}

    assert Delta.apply(base, <<0x80>>, 100) == {:error, "bad delta header"}
    # Many one-byte instructions.
    many = :binary.copy(<<1, ?z>>, 100_000)

    assert Delta.apply("", varint(0) <> varint(100_000) <> many, 100_000) ==
             {:ok, :binary.copy("z", 100_000)}

    # A copy size of 0 means 0x10000.
    big = :binary.copy("x", 0x10000)
    assert Delta.apply(big, varint(0x10000) <> varint(0x10000) <> <<0x80>>, 0x10000) == {:ok, big}
  end

  test "ids" do
    id = ObjectId.hash("x")
    assert ObjectId.from_hex(ObjectId.to_hex(id)) == {:ok, id}
    assert ObjectId.from_hex(String.upcase(ObjectId.to_hex(id))) == {:ok, id}
    assert ObjectId.from_hex("abc") == :error
    assert ObjectId.from_hex(String.duplicate("g", 40)) == :error

    assert GitServer.Object.id(:blob, "") |> ObjectId.to_hex() ==
             "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
  end
end
