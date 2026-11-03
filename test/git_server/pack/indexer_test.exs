defmodule GitServer.Pack.IndexerTest do
  use ExUnit.Case, async: true

  import GitServer.LocalGit
  import GitServer.PackBuilder

  alias GitServer.{GitFixture, Object, ObjectDB, ObjectId}
  alias GitServer.Pack.{Indexer, Writer}

  setup_all do
    home = tmp_dir!("indexer")
    on_exit(fn -> File.rm_rf!(home) end)
    fixture = GitFixture.build!(home)
    %{fixture: fixture, objects: GitFixture.objects(fixture)}
  end

  for name <- [:repacked, :ofs, :ref] do
    test "indexes the #{name} pack exactly as git does", %{fixture: f, objects: objects} do
      {pack_path, idx_path} = f.packs[unquote(name)]
      {:ok, result} = Indexer.index(pack_path)
      assert result.idx == File.read!(idx_path)

      assert ObjectId.to_hex(result.checksum) =~
               Path.basename(pack_path, ".pack") |> String.split("-") |> List.last()

      expected =
        Map.new(objects, fn {hex, type, content} ->
          {:ok, links} = Object.parse_links(type, content)
          {elem(ObjectId.from_hex(hex), 1), {type, links}}
        end)

      assert result.objects == expected
    end
  end

  test "indexes a pack from our writer as git does", %{fixture: f, objects: objects} do
    {:ok, db} = ObjectDB.open([f.packs.ref])
    ids = for {hex, _, _} <- objects, do: elem(ObjectId.from_hex(hex), 1)
    {:ok, _checksum, pieces} = Writer.write(db, ids, [], fn piece, acc -> [acc | piece] end)
    path = write(f.home, "ours.pack", IO.iodata_to_binary(pieces))
    {:ok, result} = Indexer.index(path)
    git!(f.home, f.home, ["index-pack", "-o", Path.join(f.home, "ours.idx"), path])
    assert result.idx == File.read!(Path.join(f.home, "ours.idx"))
  end

  test "limits", %{fixture: f} do
    {pack_path, _} = f.packs.repacked
    size = File.stat!(pack_path).size
    assert {:ok, _} = Indexer.index(pack_path, max_pack_bytes: size)
    assert Indexer.index(pack_path, max_pack_bytes: size - 1) == {:error, "pack too large"}
    assert Indexer.index(pack_path, max_object_bytes: 100_000) == {:error, "object too large"}
    assert Indexer.index(pack_path, max_objects: 10) == {:error, "too many objects"}
    assert Indexer.index(pack_path, max_links: 10) == {:error, "too many links"}

    assert Indexer.index(pack_path, max_work_bytes: 1_000_000) ==
             {:error, "pack needs too much work to index"}

    assert Indexer.index(pack_path, max_delta_depth: 1) == {:error, "delta chain too deep"}
    assert {:ok, _} = Indexer.index(pack_path, cache_bytes: 0)
    assert {:ok, _} = Indexer.index(pack_path, max_work_bytes: nil, cache_bytes: 0)
  end

  test "without links, checks them but neither keeps nor counts them", %{fixture: f} do
    {pack_path, idx_path} = f.packs.repacked
    {:ok, result} = Indexer.index(pack_path, max_links: 1, links: false)
    assert result.idx == File.read!(idx_path)
    assert Enum.all?(result.objects, fn {_id, {_type, links}} -> links == [] end)

    tree = object(:tree, "100644 f\0short")
    path = write(f.home, "bad-tree.pack", elem(build([tree]), 0))
    assert {:error, "malformed tree " <> _} = Indexer.index(path, links: false)
  end

  test "a bad trailer and a truncated pack", %{fixture: f} do
    {pack_path, _} = f.packs.ofs
    pack = File.read!(pack_path)

    flipped =
      binary_part(pack, 0, 100) <>
        <<Bitwise.bxor(:binary.at(pack, 100), 1)>> <>
        binary_part(pack, 101, byte_size(pack) - 101)

    assert Indexer.index(write(f.home, "flipped.pack", flipped)) ==
             {:error, "pack checksum mismatch"}

    cut = binary_part(pack, 0, byte_size(pack) - 1000)
    assert Indexer.index(write(f.home, "cut.pack", cut)) == {:error, "pack checksum mismatch"}
    assert Indexer.index(write(f.home, "tiny.pack", "PACK")) == {:error, "truncated pack"}
    assert {:error, "cannot open pack: " <> _} = Indexer.index(Path.join(f.home, "missing.pack"))

    # A valid checksum over objects that stop early, or over extra bytes.
    {short, _} = build([object(:blob, "one")], count: 2)
    assert Indexer.index(write(f.home, "short.pack", short)) == {:error, "truncated pack"}
    {long, _} = build([object(:blob, "one"), object(:blob, "two")], count: 1)
    assert Indexer.index(write(f.home, "long.pack", long)) == {:error, "pack has trailing data"}
    {not_pack, _} = build([])

    assert Indexer.index(
             write(
               f.home,
               "notpack.pack",
               "JUNK" <> binary_part(not_pack, 4, byte_size(not_pack) - 4)
             )
           ) ==
             {:error, "pack checksum mismatch"}
  end

  test "a thin pack is refused", %{fixture: f} do
    thin =
      git!(f.home, f.repo, ["pack-objects", "-q", "--thin", "--stdout", "--revs"],
        input: write(f.home, "revs", "HEAD\n^HEAD~2\n")
      )

    assert Indexer.index(write(f.home, "thin.pack", thin)) == {:error, "thin pack not supported"}
  end

  test "crafted deltas", %{fixture: f} do
    a = :binary.copy(<<0xA>>, 20)
    b = :binary.copy(<<0xB>>, 20)

    {cycle, _} =
      build([ref_delta(a, b, insert_delta(1, "a")), ref_delta(b, a, insert_delta(1, "b"))])

    assert Indexer.index(write(f.home, "cycle.pack", cycle)) ==
             {:error, "thin pack not supported"}

    big = varint(5) <> varint(2_000) <> <<0x90, 5>>
    {over, _} = build([object(:blob, "hello"), ofs_delta(a, 0, big)])

    assert Indexer.index(write(f.home, "over.pack", over), max_object_bytes: 1_000) ==
             {:error, "object too large"}

    # A REF_DELTA whose base comes later in the pack, and a delta on that delta.
    hello = object(:blob, "hello")
    world = Object.id(:blob, "hello world")
    again = Object.id(:blob, "again")
    copy = varint(5) <> varint(11) <> <<0x90, 5>> <> <<6, " world">>

    {later, _} =
      build([
        ref_delta(world, hello.id, copy),
        ofs_delta(again, 0, insert_delta(11, "again")),
        hello,
      ])

    {:ok, result} = Indexer.index(write(f.home, "later.pack", later))

    assert result.objects == %{
             hello.id => {:blob, []},
             world => {:blob, []},
             again => {:blob, []},
           }

    {dup, _} = build([hello, hello])
    assert {:error, "duplicate object " <> _} = Indexer.index(write(f.home, "dup.pack", dup))

    bad_tree = object(:tree, "100644 name\0short")
    {bad, _} = build([bad_tree])
    assert {:error, "malformed tree " <> _} = Indexer.index(write(f.home, "bad.pack", bad))
  end

  test "a REF_DELTA waits for a base that is itself a later delta", %{fixture: f} do
    a = object(:blob, "hello")
    b = Object.id(:blob, "hello world")
    c = Object.id(:blob, "brand new")
    copy = varint(5) <> varint(11) <> <<0x90, 5>> <> <<6, " world">>
    entries = [ref_delta(c, b, insert_delta(11, "brand new")), ref_delta(b, a.id, copy), a]
    assert_indexes(f, entries)
    {pack, _} = build(entries)
    {:ok, result} = Indexer.index(write(f.home, "waits.pack", pack))
    assert result.objects == %{a.id => {:blob, []}, b => {:blob, []}, c => {:blob, []}}
  end

  test "the link budget spans the whole pack" do
    dir = tmp_dir!("links")
    on_exit(fn -> File.rm_rf!(dir) end)
    entry = "100644 x\0" <> :binary.copy(<<1>>, 20)
    tag = "object #{String.duplicate("a", 40)}\ntype commit\ntag v\n"
    {pack, _} = build([object(:tree, entry <> entry), object(:tag, tag)])
    path = write(dir, "links.pack", pack)
    assert {:ok, _} = Indexer.index(path, max_links: 3)
    assert Indexer.index(path, max_links: 2) == {:error, "too many links"}
  end

  test "an empty pack", %{fixture: f} do
    {empty, _} = build([])
    {:ok, result} = Indexer.index(write(f.home, "empty.pack", empty))
    assert result.objects == %{}
  end

  describe "finding the end of a zlib stream" do
    test "the empty blob, among other objects", %{fixture: f} do
      assert_indexes(f, [object(:blob, ""), object(:blob, "x")])
      assert_indexes(f, [object(:blob, "x"), object(:blob, "", level: 0)])
    end

    test "a large object spanning many chunks", %{fixture: f} do
      assert_indexes(f, [
        object(:blob, :crypto.strong_rand_bytes(1_000_000)),
        object(:blob, "after"),
      ])
    end

    test "an Adler-32 trailer split across a chunk boundary", %{fixture: f} do
      # Stored (level 0) streams: find a size whose 4-byte trailer straddles the
      # 64 KB boundary after the object's header.
      contents =
        for n <- 65_400..65_600,
            content = :binary.copy(<<7>>, n),
            size = byte_size(compress(content, 0)),
            size - 4 < 65_536 and size > 65_536,
            do: content

      assert length(contents) == 3

      for content <- contents do
        assert_indexes(f, [object(:blob, content, level: 0), object(:blob, "after")])
      end
    end

    test "compressed bytes that contain the stream's own Adler-32 earlier", %{fixture: f} do
      content = self_adler(<<0x22, 0x33, 0x44, 0x55>>)
      assert <<:erlang.adler32(content)::32>> == <<0x22, 0x33, 0x44, 0x55>>
      stored = compress(content, 0)
      assert length(:binary.matches(stored, <<0x22, 0x33, 0x44, 0x55>>)) >= 2
      assert_indexes(f, [object(:blob, content, level: 0), object(:blob, "after")])

      small = self_adler(<<0x00, 0x10, 0x00, 0x20>>)
      assert_indexes(f, [object(:blob, small, level: 0), object(:blob, "after")])
    end

    test "a stream crafted with many false ends is refused", %{fixture: f} do
      target = <<0x22, 0x33, 0x44, 0x55>>
      content = self_adler(target)
      # Repeat the trailer bytes inside the content, keeping its Adler-32.
      padded = self_adler_with(:binary.copy(target, 40), target)
      assert :erlang.adler32(padded) == :binary.decode_unsigned(target)
      {pack, _} = build([object(:blob, padded, level: 0)])
      assert Indexer.index(write(f.home, "false-ends.pack", pack)) == {:error, "corrupt object"}
      assert_indexes(f, [object(:blob, content, level: 0)])
    end

    test "a trailer that overlaps a false match", %{fixture: f} do
      # Adler-32 0x01010101: a stored stream ends in five 0x01 bytes.
      content = <<255>> <> :binary.copy(<<0>>, 65_520) <> <<1>>
      assert :erlang.adler32(content) == 0x01010101
      assert_indexes(f, [object(:blob, content, level: 0)])
      assert_indexes(f, [object(:blob, content, level: 0), object(:blob, "after")])
    end

    test "a stream that asks for a preset dictionary, and one that isn't zlib", %{fixture: f} do
      z = :zlib.open()
      :ok = :zlib.deflateInit(z)
      _ = :zlib.deflateSetDictionary(z, "dictionary")
      data = IO.iodata_to_binary(:zlib.deflate(z, "hello", :finish))
      :zlib.close(z)
      {pack, _} = build([%{object(:blob, "hello") | data: data}])
      assert Indexer.index(write(f.home, "dict.pack", pack)) == {:error, "corrupt object"}
      {pack, _} = build([%{object(:blob, "hello") | data: "not zlib at all"}])
      assert Indexer.index(write(f.home, "notzlib.pack", pack)) == {:error, "corrupt object"}
    end

    test "an incomplete stream", %{fixture: f} do
      whole = object(:blob, String.duplicate("abc", 1000))
      cut = %{whole | data: binary_part(whole.data, 0, byte_size(whole.data) - 6)}
      {pack, _} = build([cut, object(:blob, "after")])
      assert {:error, _} = Indexer.index(write(f.home, "incomplete.pack", pack))
      {pack, _} = build([cut])
      assert {:error, _} = Indexer.index(write(f.home, "incomplete2.pack", pack))
    end

    test "a declared size that doesn't match the stream", %{fixture: f} do
      {pack, _} = build([%{object(:blob, "hello") | size: 3}])
      assert Indexer.index(write(f.home, "size.pack", pack)) == {:error, "object size mismatch"}
      {pack, _} = build([%{object(:blob, "hello") | size: 7}, object(:blob, "after")])
      assert {:error, _} = Indexer.index(write(f.home, "size2.pack", pack))
    end
  end

  # Content whose Adler-32 is `target` and which ends with `target`'s 4 bytes, so a
  # stored zlib stream of it holds the trailer twice in a row.
  defp self_adler(target), do: self_adler_with("", target)

  # Filler, then `suffix`, then `target`, with an Adler-32 of `target`. Appending
  # bytes c_0..c_(l-1) to a state (a, b) gives a + sum(c) and
  # b + l * a + sum((l - i) * c_i), so the filler is chosen to reach the state that
  # the tail then carries to `target`: first bytes to set a, then zeros, each of which
  # adds a to b.
  defp self_adler_with(suffix, target) do
    m = 65_521
    <<tb::16, ta::16>> = target
    tail = :binary.bin_to_list(suffix <> target)
    l = length(tail)
    sum = Enum.sum(tail)
    weighted = tail |> Enum.with_index() |> Enum.map(fn {c, i} -> (l - i) * c end) |> Enum.sum()
    a_p = Integer.mod(ta - sum, m)
    b_p = Integer.mod(tb - l * a_p - weighted, m)
    need = Integer.mod(a_p - 1, m)
    fill = :binary.copy(<<255>>, div(need, 255)) <> <<rem(need, 255)>>

    {_, b} =
      Enum.reduce(:binary.bin_to_list(fill), {1, 0}, fn c, {a, b} -> {a + c, b + a + c} end)

    zeros = Integer.mod((b_p - b) * inverse(a_p, m), m)
    fill <> :binary.copy(<<0>>, zeros) <> suffix <> target
  end

  # Modular inverse by Fermat's little theorem (m is prime).
  defp inverse(a, m), do: :binary.decode_unsigned(:crypto.mod_pow(a, m - 2, m))

  defp assert_indexes(f, entries) do
    {pack, idx_entries} = build(entries)
    path = write(f.home, "case-#{System.unique_integer([:positive])}.pack", pack)
    {:ok, result} = Indexer.index(path)

    assert Map.keys(result.objects) |> Enum.sort() ==
             Enum.map(idx_entries, &elem(&1, 0)) |> Enum.sort()

    idx_path = Path.rootname(path) <> ".idx"
    git!(f.home, f.home, ["index-pack", "-o", idx_path, path])
    assert result.idx == File.read!(idx_path)
  end

  defp write(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end
end
