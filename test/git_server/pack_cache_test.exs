defmodule GitServer.PackCacheTest do
  use ExUnit.Case, async: true
  import Bitwise
  import GitServer.TestGit
  alias GitServer.CountingStore
  alias GitServer.ObjectDB
  alias GitServer.Object
  alias GitServer.PackBuilder
  alias GitServer.PackCache
  alias GitServer.Repository
  alias GitServer.State
  alias GitServer.Store
  alias GitServer.TestServer
  alias GitServer.Pack.Idx

  @moduletag :tmp_dir

  defp commit!(dir, file, content) do
    File.write!(Path.join(dir, file), content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", "change"], cd: dir)
  end

  defp clone!(server, repo, dir) do
    {_, 0} = git(["clone", "-q", TestServer.url(server, repo), dir])
    {log, 0} = git(["log", "--format=%s"], cd: dir)
    length(String.split(log, "\n", trim: true))
  end

  defp cache_files(dir) do
    dir |> File.ls!() |> Enum.sort()
  end

  test "a warm clone reads only the state, and a cold one the same as with no cache", %{
    tmp_dir: tmp_dir,
  } do
    inner = GitServer.TestStore.fresh()
    store = CountingStore.wrap(inner)
    cache_dir = Path.join(tmp_dir, "cache")
    cached = TestServer.start!(store: store, pack_cache_dir: cache_dir)
    plain = TestServer.start!(store: store)

    local = Path.join(tmp_dir, "local")
    {_, 0} = git(["init", "-q", "-b", "main", local])

    for i <- 1..30 do
      commit!(local, "f", "#{i}\n")
      {_, 0} = git(["push", "-q", TestServer.url(plain, "r"), "main"], cd: local)
    end

    # No cache: every pack and idx, each clone.
    CountingStore.reset(store)
    assert clone!(plain, "r", Path.join(tmp_dir, "plain")) == 30
    assert %{get_files: 60, gets: gets, deletes: 0} = CountingStore.counts(store)

    # A cold cache downloads the same, and a warm one nothing but the state.
    CountingStore.reset(store)
    assert clone!(cached, "r", Path.join(tmp_dir, "cold")) == 30
    assert CountingStore.counts(store) == %{get_files: 60, gets: gets, deletes: 0}
    assert length(cache_files(cache_dir)) == 60

    CountingStore.reset(store)
    assert clone!(cached, "r", Path.join(tmp_dir, "warm")) == 30
    assert CountingStore.counts(store) == %{get_files: 0, gets: gets, deletes: 0}

    # A push through the cached server takes the packs from the cache too.
    commit!(local, "f", "31\n")
    CountingStore.reset(store)
    {_, 0} = git(["push", "-q", TestServer.url(cached, "r"), "main"], cd: local)
    assert CountingStore.counts(store).get_files == 0
    assert (File.stat!(cache_dir).mode &&& 0o777) == 0o700
  end

  # Packs of one blob each, stored under `repo` and listed in its state.
  defp seed_packs!(store, repo, n) do
    names =
      for i <- 1..n do
        entry = PackBuilder.object(:blob, "blob #{i}\n")
        {pack, entries} = PackBuilder.build([entry])
        checksum = binary_part(pack, byte_size(pack) - 20, 20)
        name = Base.encode16(checksum, case: :lower)
        {:ok, _} = Store.put(store, Repository.pack_key(repo, name), pack, :none)

        {:ok, _} =
          Store.put(store, Repository.idx_key(repo, name), Idx.encode(entries, checksum), :none)

        name
      end

    {:ok, _} = Repository.put_state(store, repo, %State{packs: names}, :absent)
    for i <- 1..n, do: "blob #{i}\n"
  end

  defp read_all!(snapshot, blobs) do
    {:ok, db} = ObjectDB.open(snapshot.packs)

    for blob <- blobs,
        do: assert(ObjectDB.read(db, Object.id(:blob, blob)) == {:ok, :blob, blob})

    ObjectDB.close(db)
  end

  test "eviction keeps the cache under its cap and never takes a request's files", %{
    tmp_dir: tmp_dir,
  } do
    store = GitServer.TestStore.fresh()
    blobs = seed_packs!(store, "r", 10)
    cache_dir = Path.join(tmp_dir, "cache")

    {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir, cache: {cache_dir, 1_000_000})
    assert length(cache_files(cache_dir)) == 20
    Repository.release(snapshot)

    sizes = for f <- cache_files(cache_dir), do: File.stat!(Path.join(cache_dir, f)).size
    entry = div(Enum.sum(sizes), 10)

    # A request holding every entry, then a cap that leaves room for three.
    {:ok, holding} = Repository.snapshot(store, "r", tmp_dir, cache: {cache_dir, 1_000_000})
    {:ok, cache} = PackCache.open(cache_dir, 3 * entry + div(entry, 2), store)
    PackCache.evict(cache)
    assert length(cache_files(cache_dir)) == 6
    {:ok, cache} = PackCache.open(cache_dir, 0, store)
    PackCache.evict(cache)
    assert cache_files(cache_dir) == []
    read_all!(holding, blobs)
    Repository.release(holding)
  end

  test "eviction takes the least recently used, and a hit counts as a use", %{
    tmp_dir: tmp_dir,
  } do
    store = GitServer.TestStore.fresh()
    seed_packs!(store, "r", 4)
    {:ok, %State{packs: names}, _} = Repository.read_state(store, "r")
    cache_dir = Path.join(tmp_dir, "cache")
    {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir, cache: {cache_dir, 1_000_000})
    Repository.release(snapshot)
    {:ok, cache} = PackCache.open(cache_dir, 1_000_000, store)

    # Entry i was last used i + 2 hours ago, so the last two are the oldest.
    now = System.os_time(:second)
    hashes = for name <- names, do: hash(cache_dir, store, name)

    for {hash, i} <- Enum.with_index(hashes),
        do: File.touch!(Path.join(cache_dir, hash <> ".pack"), now - (i + 2) * 3600)

    # A hit on the oldest makes it the newest.
    oldest = List.last(names)
    target = Path.join(tmp_dir, "taken")

    assert PackCache.take(
             cache,
             Repository.pack_key("r", oldest),
             target <> ".pack",
             target <> ".idx"
           ) == :ok

    size =
      for(f <- cache_files(cache_dir), do: File.stat!(Path.join(cache_dir, f)).size) |> Enum.sum()

    {:ok, small} = PackCache.open(cache_dir, div(size, 2) + 1, store)
    PackCache.evict(small)

    [first, _second, _third, last] = hashes

    assert cache_files(cache_dir) ==
             Enum.sort(for h <- [first, last], ext <- [".idx", ".pack"], do: h <> ext)
  end

  test "a take of an entry whose pack is gone misses and recreates nothing", %{
    tmp_dir: tmp_dir,
  } do
    store = GitServer.TestStore.fresh()
    seed_packs!(store, "r", 1)
    {:ok, %State{packs: [name]}, _} = Repository.read_state(store, "r")
    cache_dir = Path.join(tmp_dir, "cache")
    {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir, cache: {cache_dir, 1_000_000})
    Repository.release(snapshot)
    {:ok, cache} = PackCache.open(cache_dir, 1_000_000, store)
    File.rm!(Path.join(cache_dir, hash(cache_dir, store, name) <> ".pack"))

    target = Path.join(tmp_dir, "taken")

    assert PackCache.take(
             cache,
             Repository.pack_key("r", name),
             target <> ".pack",
             target <> ".idx"
           ) == :miss

    refute File.exists?(target <> ".idx")
    assert cache_files(cache_dir) == [hash(cache_dir, store, name) <> ".idx"]
  end

  # The name an entry's files have, as PackCache names them.
  defp hash(_cache_dir, store, name) do
    key = Repository.pack_key("r", name)
    Base.encode16(:crypto.hash(:sha256, [Store.describe(store), 0, key]), case: :lower)
  end

  test "requests inserting, taking and evicting at once all read the right objects", %{
    tmp_dir: tmp_dir,
  } do
    store = GitServer.TestStore.fresh()
    blobs = seed_packs!(store, "r", 12)
    cache_dir = Path.join(tmp_dir, "cache")

    # A cap of a few entries, so every request evicts what others are taking.
    1..16
    |> Task.async_stream(
      fn _ ->
        {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir, cache: {cache_dir, 2_000})
        read_all!(snapshot, blobs)
        Repository.release(snapshot)
      end,
      max_concurrency: 16,
      timeout: 60_000
    )
    |> Enum.each(fn result -> assert {:ok, _} = result end)

    total =
      Enum.sum(for f <- cache_files(cache_dir), do: File.stat!(Path.join(cache_dir, f)).size)

    assert total <= 2_000
  end

  test "an idx that doesn't fit its pack is refused, and a repaired one is cached", %{
    tmp_dir: tmp_dir,
  } do
    store = GitServer.TestStore.fresh()
    blobs = ["one\n", "two\n"]
    {pack, entries} = PackBuilder.build(Enum.map(blobs, &PackBuilder.object(:blob, &1)))
    checksum = binary_part(pack, byte_size(pack) - 20, 20)
    name = Base.encode16(checksum, case: :lower)
    {:ok, _} = Store.put(store, Repository.pack_key("r", name), pack, :none)
    {:ok, _} = Repository.put_state(store, "r", %State{packs: [name]}, :absent)

    # Well formed, with a good checksum, but both ids at the first object's offset.
    [{id1, offset, crc}, {id2, _, _}] = entries
    bad = Idx.encode([{id1, offset, crc}, {id2, offset, crc}], checksum)
    {:ok, _} = Store.put(store, Repository.idx_key("r", name), bad, :none)
    cache = {Path.join(tmp_dir, "cache"), 1_000_000}

    assert Repository.snapshot(store, "r", tmp_dir, cache: cache) ==
             {:error, "repository r: pack #{name}: pack index doesn't match pack"}

    assert cache_files(Path.join(tmp_dir, "cache")) == []

    {:ok, _} =
      Store.put(store, Repository.idx_key("r", name), Idx.encode(entries, checksum), :none)

    {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir, cache: cache)
    read_all!(snapshot, blobs)
    Repository.release(snapshot)
    assert length(cache_files(Path.join(tmp_dir, "cache"))) == 2
  end

  test "the cache directory may not take a request directory's name" do
    assert {:error, message} =
             GitServer.Config.resolve(
               store: GitServer.TestStore.fresh(),
               authorize: fn _ -> :ok end,
               pack_cache_dir: "/tmp/git_server-cache"
             )

    assert message =~ "pack_cache_dir"
  end
end
