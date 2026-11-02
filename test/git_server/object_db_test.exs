defmodule GitServer.ObjectDBTest do
  use ExUnit.Case, async: true

  import GitServer.LocalGit

  alias GitServer.{GitFixture, Object, ObjectDB, ObjectId, Pack}
  alias GitServer.Pack.{Idx, Writer}

  setup_all do
    home = tmp_dir!("object_db")
    on_exit(fn -> File.rm_rf!(home) end)
    fixture = GitFixture.build!(home)
    %{fixture: fixture, objects: GitFixture.objects(fixture)}
  end

  for name <- [:repacked, :ofs, :ref] do
    test "reads every object of the #{name} pack as git does", %{fixture: f, objects: objects} do
      {:ok, db} = ObjectDB.open([f.packs[unquote(name)]])

      for {hex, type, content} <- objects do
        {:ok, id} = ObjectId.from_hex(hex)
        assert ObjectDB.read(db, id) == {:ok, type, content}
        assert ObjectDB.lookup(db, id) == {:ok, type, byte_size(content)}
      end

      assert ObjectDB.read(db, ObjectId.zero()) == :error
      assert ObjectDB.lookup(db, ObjectId.zero()) == :error
      ObjectDB.close(db)
    end
  end

  test "the fixture packs hold the delta kinds they're meant to", %{fixture: f} do
    assert :ofs in kinds(f.packs.repacked)
    assert :ofs in kinds(f.packs.ofs)
    refute :ref in kinds(f.packs.ofs)
    assert :ref in kinds(f.packs.ref)
    refute :ofs in kinds(f.packs.ref)
  end

  defp kinds({pack_path, idx_path}) do
    {:ok, idx} = Idx.decode(File.read!(idx_path))
    pack = File.read!(pack_path)

    for {_id, offset} <- Idx.entries(idx), uniq: true do
      {:ok, kind, _size, _used} =
        Pack.parse_object_header(
          binary_part(pack, offset, min(40, byte_size(pack) - offset)),
          offset
        )

      elem(kind, 0)
    end
  end

  test "reads across several packs", %{fixture: f, objects: objects} do
    {:ok, db} = ObjectDB.open([f.packs.ref, f.packs.ofs])

    for {hex, type, content} <- objects do
      assert ObjectDB.read(db, elem(ObjectId.from_hex(hex), 1)) == {:ok, type, content}
    end
  end

  test "reads through a cache too small to hold anything, or only a little", %{
    fixture: f,
    objects: objects,
  } do
    for cache_bytes <- [0, 5_000, 300_000] do
      {:ok, db} = ObjectDB.open([f.packs.repacked], cache_bytes: cache_bytes)

      for {hex, type, content} <- Enum.shuffle(objects) do
        assert ObjectDB.read(db, elem(ObjectId.from_hex(hex), 1)) == {:ok, type, content}
      end
    end
  end

  test "follows only as many deltas as allowed", %{fixture: f, objects: objects} do
    {:ok, db} = ObjectDB.open([f.packs.repacked], max_delta_depth: 0)
    results = for {hex, _, _} <- objects, do: ObjectDB.read(db, elem(ObjectId.from_hex(hex), 1))
    assert {:error, "delta chain too deep"} in results
  end

  test "refuses objects over the size cap", %{fixture: f} do
    {:ok, db} = ObjectDB.open([f.packs.repacked], max_object_bytes: 1000)
    {:ok, id} = ObjectId.from_hex(rev_parse(f, "HEAD:big.txt"))
    assert ObjectDB.read(db, id) == {:error, "object too large"}
    assert ObjectDB.lookup(db, id) == {:error, "object too large"}
  end

  test "an idx must belong to its pack", %{fixture: f} do
    {ofs_pack, _} = f.packs.ofs
    {_, ref_idx} = f.packs.ref
    assert ObjectDB.open([{ofs_pack, ref_idx}]) == {:error, "pack index doesn't match pack"}

    corrupt = Path.join(f.home, "corrupt.idx")
    idx = File.read!(ref_idx)

    File.write!(
      corrupt,
      binary_part(idx, 0, 2000) <> "x" <> binary_part(idx, 2001, byte_size(idx) - 2001)
    )

    assert ObjectDB.open([{ofs_pack, corrupt}]) == {:error, "pack index checksum mismatch"}
    assert {:error, "cannot read pack index: " <> _} = ObjectDB.open([{ofs_pack, corrupt <> "x"}])
  end

  test "idx encoding is byte-identical to git's", %{fixture: f} do
    for {_pack_path, idx_path} <- Map.values(f.packs) do
      git_idx = File.read!(idx_path)
      {:ok, idx} = Idx.decode(git_idx)

      entries =
        idx
        |> Idx.entries()
        |> Enum.with_index(fn {id, offset}, i -> {id, offset, Idx.crc_at(idx, i)} end)

      assert Idx.encode(Enum.shuffle(entries), idx.pack_checksum) == git_idx
    end
  end

  test "idx encodes and finds offsets past 2 GB" do
    ids = for _ <- 1..3, do: :crypto.strong_rand_bytes(20)

    entries =
      Enum.zip_with(ids, [12, 0x80000000, 0x1_0000_0000], fn id, offset -> {id, offset, 7} end)

    {:ok, idx} = Idx.decode(Idx.encode(entries, ObjectId.zero()))

    for {id, offset, _} <- entries, do: assert(Idx.offset(idx, id) == {:ok, offset})
    assert Idx.offset(idx, ObjectId.zero()) == :error
    assert Idx.member?(idx, hd(ids))
  end

  test "an empty idx" do
    {:ok, idx} = Idx.decode(Idx.encode([], ObjectId.zero()))
    assert idx.count == 0
    assert Idx.entries(idx) == []
    assert Idx.offset(idx, ObjectId.zero()) == :error
  end

  test "parses links as git sees them", %{fixture: f, objects: objects} do
    for {hex, type, content} <- objects do
      {:ok, links} = ObjectDB.parse_links(type, content)
      assert Enum.sort(links) == Enum.sort(expected_links(f, hex, type, content))
    end
  end

  defp expected_links(_f, _hex, :blob, _content), do: []

  defp expected_links(f, hex, :commit, _content) do
    [tree | parents] = String.split(git(f, ["log", "-1", "--format=%T %P", hex]))
    [{:tree, id(tree)} | Enum.map(parents, &{:commit, id(&1)})]
  end

  defp expected_links(f, hex, :tree, _content) do
    for line <- String.split(git(f, ["ls-tree", hex]), "\n", trim: true),
        [_mode, type, oid] = String.split(hd(String.split(line, "\t"))),
        type != "commit",
        do: {String.to_existing_atom(type), id(oid)}
  end

  defp expected_links(_f, _hex, :tag, content) do
    ["object " <> oid, "type " <> type | _] = String.split(content, "\n")
    [{String.to_existing_atom(type), id(oid)}]
  end

  test "the fixture has a gitlink, which parse_links leaves out", %{fixture: f} do
    tree = rev_parse(f, "HEAD^{tree}")
    assert git(f, ["ls-tree", tree]) =~ "160000 commit"
  end

  test "rejects malformed objects" do
    assert Object.parse_links(:commit, "tree nothex\n") == {:error, "malformed commit"}
    tree = "tree #{String.duplicate("a", 40)}\n"
    assert Object.parse_links(:commit, tree <> "parent nothex\n") == {:error, "malformed commit"}

    assert {:ok, [_, _]} =
             Object.parse_links(
               :commit,
               tree <> "parent #{String.duplicate("b", 40)}\nauthor x\n"
             )

    assert Object.parse_links(:tag, "object #{String.duplicate("a", 40)}\ntype tree\n") ==
             {:ok, [{:tree, :binary.copy(<<0xAA>>, 20)}]}

    assert Object.parse_links(:tag, "object #{String.duplicate("a", 40)}\ntype bogus\n") ==
             {:error, "malformed tag"}

    assert Object.parse_links(:tree, "100644 name\0short") == {:error, "malformed tree"}
    entry = "100644 x\0" <> :binary.copy(<<1>>, 20)
    assert {:ok, [_, _]} = Object.parse_links(:tree, entry <> entry, 2)
    assert Object.parse_links(:tree, entry <> entry <> entry, 2) == {:error, "too many links"}
    gitlink = "160000 g\0" <> :binary.copy(<<2>>, 20)
    assert Object.parse_links(:tree, gitlink, 0) == {:ok, []}
    assert {:ok, [_, _]} = Object.parse_links(:tree, entry <> entry <> gitlink, 2)
    root = "tree #{String.duplicate("a", 40)}\nauthor x\n"
    assert Object.parse_links(:commit, root, 0) == {:error, "too many links"}
    assert {:ok, [_]} = Object.parse_links(:commit, root, 1)
    tag = "object #{String.duplicate("a", 40)}\ntype commit\ntag v\n"
    assert Object.parse_links(:tag, tag, 0) == {:error, "too many links"}
    assert {:ok, [_]} = Object.parse_links(:tag, tag, 1)
    parent = "parent #{String.duplicate("b", 40)}\n"

    assert Object.parse_links(
             :commit,
             "tree #{String.duplicate("a", 40)}\n" <> parent <> parent,
             2
           ) == {:error, "too many links"}

    assert Object.parse_links(:tree, "100644 \0" <> :binary.copy(<<1>>, 20)) ==
             {:error, "malformed tree"}

    assert Object.parse_links(:tree, "170000 x\0" <> :binary.copy(<<1>>, 20)) ==
             {:error, "malformed tree"}
  end

  test "a pack from the writer passes git index-pack and verify-pack", %{
    fixture: f,
    objects: objects,
  } do
    {:ok, db} = ObjectDB.open([f.packs.ofs])
    ids = for {hex, _, _} <- objects, do: elem(ObjectId.from_hex(hex), 1)
    {:ok, checksum, pieces} = Writer.write(db, ids, [], fn piece, acc -> [acc | piece] end)
    pack = IO.iodata_to_binary(pieces)
    assert binary_part(pack, byte_size(pack) - 20, 20) == checksum
    assert ObjectId.hash(binary_part(pack, 0, byte_size(pack) - 20)) == checksum

    dest = Path.join(f.home, "dest")
    git!(f.home, f.home, ["init", "-q", "--bare", dest])
    pack_path = Path.join(dest, "objects/pack/pack-#{ObjectId.to_hex(checksum)}.pack")
    File.write!(pack_path, pack)
    git!(f.home, dest, ["index-pack", pack_path])
    git!(f.home, dest, ["verify-pack", "-v", pack_path])

    copied = GitFixture.objects(%{home: f.home, repo: dest})
    assert Enum.sort(copied) == Enum.sort(objects)
  end

  test "the writer reports a missing object", %{fixture: f} do
    {:ok, db} = ObjectDB.open([f.packs.ofs])
    missing = ObjectId.zero()

    assert {:error, "missing object " <> _, _acc} =
             Writer.write(db, [missing], [], fn piece, acc -> [acc | piece] end)
  end

  defp rev_parse(f, rev), do: String.trim(git(f, ["rev-parse", rev]))
  defp git(f, args), do: git!(f.home, f.repo, args)
  defp id(hex), do: elem(ObjectId.from_hex(hex), 1)
end
