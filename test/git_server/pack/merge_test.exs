defmodule GitServer.Pack.MergeTest do
  # Merging local packs: what is copied, rewritten or written whole, checked with
  # git's own verify-pack.
  use ExUnit.Case, async: true

  import Bitwise
  import GitServer.LocalGit
  import GitServer.PackBuilder

  alias GitServer.GitFixture
  alias GitServer.Object
  alias GitServer.ObjectId
  alias GitServer.Pack
  alias GitServer.Pack.Idx
  alias GitServer.Pack.Indexer
  alias GitServer.Pack.Merge

  setup_all do
    home = tmp_dir!("merge")
    on_exit(fn -> File.rm_rf!(home) end)
    %{fixture: GitFixture.build!(home)}
  end

  # A pack and its idx from PackBuilder entries, as files.
  defp pack_files!(dir, name, entries) do
    {pack, idx_entries} = build(entries)
    pack_path = Path.join(dir, "#{name}.pack")
    idx_path = Path.join(dir, "#{name}.idx")
    File.write!(pack_path, pack)
    File.write!(idx_path, Idx.encode(idx_entries, binary_part(pack, byte_size(pack) - 20, 20)))
    {pack_path, idx_path}
  end

  # verify-pack's view of a pack: id => nil for a whole object, or its delta base's id.
  defp bases(home, pack_path) do
    out = Path.join(home, "verify-#{System.unique_integer([:positive])}.pack")
    File.cp!(pack_path, out)
    git!(home, home, ["index-pack", out])
    output = git!(home, home, ["verify-pack", "-v", Path.rootname(out) <> ".idx"])

    for line <- String.split(output, "\n"),
        [id, _type, _size, _packed, _offset | rest] <- [String.split(line)],
        id =~ ~r/\A[0-9a-f]{40}\z/,
        into: %{},
        do: {id, List.last([nil | Enum.drop(rest, 1)])}
  end

  # Copies the whole base, then inserts `tail`.
  defp copy_delta(base, tail) do
    size = byte_size(base)

    varint(size) <>
      varint(size + byte_size(tail)) <>
      <<0xF0, band(size, 0xFF), band(size >>> 8, 0xFF), size >>> 16>> <>
      <<byte_size(tail)>> <> tail
  end

  defp blob(content) do
    object(:blob, content)
  end

  defp id(content) do
    Object.id(:blob, content)
  end

  test "merges git's packs into one holding each object once, as git indexes it",
       %{fixture: f} do
    out = Path.join(f.home, "merged-git.pack")
    inputs = [f.packs.ofs, f.packs.ref, f.packs.repacked]
    {:ok, checksum, ids} = Merge.write(inputs, out)

    {:ok, idx} = Idx.decode(File.read!(elem(f.packs.ofs, 1)))
    assert ids == MapSet.new(Idx.entries(idx), &elem(&1, 0))
    {:ok, indexed} = Indexer.index(out)
    assert indexed.checksum == checksum
    assert MapSet.new(Map.keys(indexed.objects)) == ids

    # The first input's entries come over as they were: deltas stay deltas.
    assert bases(f.home, out) == bases(f.home, elem(f.packs.ofs, 0))
  end

  test "a delta whose base was a dropped duplicate is written whole, others stay deltas" do
    dir = tmp_dir!("merge-dup")
    x = :crypto.strong_rand_bytes(3000)
    v = :crypto.strong_rand_bytes(3000)
    y = x <> "y"
    z = x <> "z"
    u = v <> "u"
    a = pack_files!(dir, "a", [blob(x)])

    b =
      pack_files!(dir, "b", [
        blob(x),
        ofs_delta(id(y), 0, copy_delta(x, "y")),
        ref_delta(id(z), id(x), copy_delta(x, "z")),
        blob(v),
        ofs_delta(id(u), 3, copy_delta(v, "u")),
      ])

    out = Path.join(dir, "merged.pack")
    {:ok, _checksum, ids} = Merge.write([a, b], out)
    assert ids == MapSet.new([id(x), id(y), id(z), id(v), id(u)])
    {:ok, indexed} = Indexer.index(out)
    assert MapSet.new(Map.keys(indexed.objects)) == ids

    hexes = &ObjectId.to_hex/1

    assert bases(dir, out) == %{
             hexes.(id(x)) => nil,
             hexes.(id(y)) => nil,
             hexes.(id(z)) => nil,
             hexes.(id(v)) => nil,
             hexes.(id(u)) => hexes.(id(v)),
           }

    File.rm_rf!(dir)
  end

  test "keeps a REF_DELTA before its base, and rewrites OFS_DELTA distances of every width" do
    dir = tmp_dir!("merge-ofs")
    base = :crypto.strong_rand_bytes(20_000)
    later = base <> "later"
    filler = Enum.map(1..3, &blob(:crypto.strong_rand_bytes(&1 * 70)))
    # A forward REF_DELTA, then the base, then OFS_DELTAs at growing distances.
    entries =
      [ref_delta(id(later), id(base), copy_delta(base, "later")), blob(base)] ++
        Enum.flat_map(Enum.with_index(filler), fn {f, i} ->
          [f, ofs_delta(id(base <> "#{i}"), 1, copy_delta(base, "#{i}"))]
        end)

    # A dropped duplicate in front shifts every offset in the output.
    first = pack_files!(dir, "first", [Enum.at(filler, 0)])
    second = pack_files!(dir, "second", entries)
    out = Path.join(dir, "merged.pack")
    {:ok, _checksum, ids} = Merge.write([first, second], out)
    {:ok, indexed} = Indexer.index(out)
    assert MapSet.new(Map.keys(indexed.objects)) == ids
    deltas = bases(dir, out)
    assert deltas[ObjectId.to_hex(id(later))] == ObjectId.to_hex(id(base))

    for i <- 0..2,
        do: assert(deltas[ObjectId.to_hex(id(base <> "#{i}"))] == ObjectId.to_hex(id(base)))

    File.rm_rf!(dir)
  end

  test "a dropped entry between a delta and its base shortens the base distance" do
    dir = tmp_dir!("merge-shrink")
    base = :crypto.strong_rand_bytes(100)
    filler = blob(:crypto.strong_rand_bytes(400))
    first = pack_files!(dir, "first", [filler])
    # base, then 400+ bytes of filler: a 2-byte distance, 1 byte once filler drops out.
    second =
      pack_files!(dir, "second", [
        blob(base),
        filler,
        ofs_delta(id(base <> "!"), 0, copy_delta(base, "!")),
      ])

    out = Path.join(dir, "merged.pack")
    {:ok, _checksum, ids} = Merge.write([first, second], out)
    {:ok, indexed} = Indexer.index(out)
    assert MapSet.new(Map.keys(indexed.objects)) == ids
    assert bases(dir, out)[ObjectId.to_hex(id(base <> "!"))] == ObjectId.to_hex(id(base))
    File.rm_rf!(dir)
  end

  test "a chain whose middle is written whole keeps its top as a delta on it" do
    dir = tmp_dir!("merge-chain")
    x = :crypto.strong_rand_bytes(3000)
    y = x <> "y"
    z = y <> "z"
    first = pack_files!(dir, "first", [blob(x)])

    second =
      pack_files!(dir, "second", [
        blob(x),
        ofs_delta(id(y), 0, copy_delta(x, "y")),
        ofs_delta(id(z), 1, copy_delta(y, "z")),
      ])

    out = Path.join(dir, "merged.pack")
    {:ok, _checksum, ids} = Merge.write([first, second], out)
    {:ok, indexed} = Indexer.index(out)
    assert MapSet.new(Map.keys(indexed.objects)) == ids
    deltas = bases(dir, out)
    assert deltas[ObjectId.to_hex(id(y))] == nil
    assert deltas[ObjectId.to_hex(id(z))] == ObjectId.to_hex(id(y))
    File.rm_rf!(dir)
  end

  test "OFS_DELTA headers round-trip at every distance width" do
    for distance <- [1, 127, 128, 16_511, 16_512, 2_113_663, 2_113_664, 1 <<< 35],
        size <- [0, 15, 16, 1_000_000] do
      header = Pack.encode_ofs_delta_header(size, distance)
      offset = distance + Pack.header_size()

      assert {:ok, {:ofs, 12}, ^size, used} = Pack.parse_object_header(header, offset)
      assert used == byte_size(header)
    end
  end

  test "stops at a size cap, as soon as the pack would pass it, naming the input",
       %{fixture: f} do
    out = Path.join(f.home, "capped.pack")
    {pack_path, _} = f.packs.repacked
    size = File.stat!(pack_path).size
    assert {:ok, _, _} = Merge.write([f.packs.repacked], out, [], size)
    assert Merge.write([f.packs.repacked], out, [], size - 1) == {:error, {:too_large, 0}}
  end

  test "a missing or corrupt input fails" do
    dir = tmp_dir!("merge-bad")
    {pack_path, idx_path} = pack_files!(dir, "a", [blob("one"), blob("two")])
    out = Path.join(dir, "merged.pack")
    assert {:error, "cannot read pack index: " <> _} = Merge.write([{pack_path, "nope"}], out)

    # An idx whose offsets don't match the pack.
    File.write!(idx_path, Idx.encode([{id("one"), 12, 0}, {id("two"), 13, 0}], <<0::160>>))
    assert {:error, "pack index doesn't match pack"} = Merge.write([{pack_path, idx_path}], out)
    File.rm_rf!(dir)
  end
end
