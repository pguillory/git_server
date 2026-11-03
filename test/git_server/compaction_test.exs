defmodule GitServer.CompactionTest do
  # Compaction with the real git client and a real store: what it merges, that it
  # keeps every object and deletes nothing, and every race with pushes, force pushes,
  # fetches and other compactions, each ending with the repository whole.
  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureLog
  import GitServer.TestGit

  alias GitServer.{
    Compaction,
    CountingStore,
    FailingStore,
    Invariant,
    Object,
    ObjectId,
    OutageStore,
    PackBuilder,
    RacingStore,
    Repository,
    Seed,
    State,
    Store,
    TestServer
  }

  alias GitServer.Pack.Idx

  @moduletag :tmp_dir

  @repo "team"
  @stress_ms 10_000

  defp opts(store, tmp_dir, extra \\ []) do
    [store: store, authorize: fn _ -> :ok end, temp_dir: work_dir(tmp_dir)] ++ extra
  end

  defp work_dir(tmp_dir) do
    dir = Path.join(tmp_dir, "work")
    File.mkdir_p!(dir)
    dir
  end

  defp state(store, repo \\ @repo) do
    {:ok, state, _etag} = Repository.read_state(store, repo)
    state
  end

  defp commit!(dir, file, content, message \\ "change") do
    File.write!(Path.join(dir, file), content)
    {_, 0} = git(["add", "-A"], cd: dir)
    {_, 0} = git(["commit", "-q", "-m", message], cd: dir)
    rev!(dir, "HEAD")
  end

  defp rev!(dir, rev) do
    {id, 0} = git(["rev-parse", rev], cd: dir)
    String.trim(id)
  end

  # A clone of `url` in `dir` with `n` pushes made from it, one commit each.
  defp pushes!(url, dir, n) do
    {_, 0} = git(["clone", "-q", url, dir])

    for i <- 1..n//1 do
      commit!(dir, "file-#{rem(i, 5)}.txt", "push #{i}\n#{String.duplicate("line\n", i)}")
      {_, 0} = git(["push", "-q", "origin", "HEAD:main"], cd: dir)
    end

    dir
  end

  # A fresh clone, checked with fsck, then removed. Returns its main.
  defp clone!(url, tmp_dir) do
    dir = Path.join(tmp_dir, "clone-#{System.unique_integer([:positive])}")
    {output, status} = git(["clone", "-q", url, dir])
    assert status == 0, output
    {_, 0} = git(["fsck", "--full", "--no-dangling"], cd: dir)
    head = rev!(dir, "HEAD")
    File.rm_rf!(dir)
    head
  end

  # The ids in packs, from git's show-index of each stored idx.
  defp packed_ids(store, names, tmp_dir, repo \\ @repo) do
    dir = Path.join(tmp_dir, "ids-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ids =
      MapSet.new(
        Enum.flat_map(names, fn name ->
          idx = Path.join(dir, "#{name}.idx")
          {:ok, _} = Store.get_file(store, Repository.idx_key(repo, name), idx)
          {output, 0} = System.cmd("sh", ["-c", ~s(git show-index < "$0"), idx])
          for line <- String.split(output, "\n", trim: true), do: Enum.at(String.split(line), 1)
        end)
      )

    File.rm_rf!(dir)
    ids
  end

  defp exists?(store, repo, name) do
    {:ok, _, _} = Store.get(store, Repository.idx_key(repo, name))
    match?({:ok, _, _}, Store.get(store, Repository.pack_key(repo, name)))
  end

  # `n` packs of one new commit each, written straight to the store.
  defp seed_packs!(store, tmp_dir, n, repo \\ @repo) do
    source = Seed.source!(Path.join(tmp_dir, "seed-#{System.unique_integer([:positive])}"))

    for i <- 1..n do
      commit = Seed.commit!(source, "f#{i}", "seeded #{i}\n")
      revs = if i == 1, do: [commit], else: [commit, "^#{commit}~"]
      Seed.push!(store, repo, source, revs)
    end

    source
  end

  # A pack built byte by byte, stored with its idx: its name.
  defp put_built!(store, entries, repo \\ @repo) do
    {pack, idx_entries} = PackBuilder.build(entries)
    checksum = binary_part(pack, byte_size(pack) - 20, 20)
    name = ObjectId.to_hex(checksum)
    {:ok, _} = Store.put(store, Repository.pack_key(repo, name), pack, :none)

    {:ok, _} =
      Store.put(store, Repository.idx_key(repo, name), Idx.encode(idx_entries, checksum), :none)

    name
  end

  defp list_packs!(store, names, repo \\ @repo) do
    {:ok, %State{} = state, etag} = Repository.read_state(store, repo)
    {:ok, _} = Repository.put_state(store, repo, %{state | packs: names}, etag)
  end

  # Copies the whole base, then inserts `tail`.
  defp copy_delta(base, tail) do
    size = byte_size(base)

    PackBuilder.varint(size) <>
      PackBuilder.varint(size + byte_size(tail)) <>
      <<0xF0, band(size, 0xFF), band(size >>> 8, 0xFF), size >>> 16>> <>
      <<byte_size(tail)>> <> tail
  end

  describe "choosing packs" do
    defp sizes(list), do: Enum.with_index(list, fn bytes, i -> {"p#{i}", bytes, 1} end)

    test "nothing at or under max_packs, and never a single pack" do
      assert Compaction.choose(sizes([1, 1, 1]), max_packs: 3) == []
      assert Compaction.choose(sizes([1, 1, 1]), max_packs: 2) == ["p0", "p1", "p2"]
      # Already a progression: each at least twice the one below.
      assert Compaction.choose(sizes([1, 2, 4, 8, 16]), max_packs: 0) == []
      assert Compaction.choose(sizes([100]), max_packs: 0) == []
    end

    test "the smallest packs roll up until each left is twice the next smaller" do
      # 1, 1 break the progression; 2 < 2 * (1 + 1) joins; 8 >= 2 * 4 stays.
      assert Compaction.choose(sizes([8, 1, 1, 2, 32]), max_packs: 0) == ["p1", "p2", "p3"]
      # Equal packs all merge.
      assert Compaction.choose(sizes([5, 5, 5, 5]), max_packs: 0) == ["p0", "p1", "p2", "p3"]
    end

    test "the largest drop out while over the byte or object cap" do
      chosen = Compaction.choose(sizes([5, 5, 5, 5]), max_packs: 0, max_compact_bytes: 12)
      assert chosen == ["p0", "p1"]

      counted = [{"a", 5, 10}, {"b", 5, 10}, {"c", 5, 10}]
      assert Compaction.choose(counted, max_packs: 0, max_compact_objects: 20) == ["a", "b"]
      assert Compaction.choose(counted, max_packs: 0, max_compact_objects: 19) == []
    end
  end

  describe "the state change" do
    defp state_with(packs), do: %State{packs: packs, refs: %{"refs/heads/main" => "x"}}

    test "replaces the inputs at the first one's place and keeps refs and head" do
      state = state_with(~w(a b c d))
      assert {:write, new, 3} = Compaction.replace(state, ~w(b d), "m")
      assert new == %{state | packs: ~w(a m c)}
    end

    test "stops if any input is gone: another compaction got there" do
      assert Compaction.replace(state_with(~w(a m c)), ~w(b d), "n") == {:stop, :superseded}
      assert Compaction.replace(state_with(~w(a c d)), ~w(b d), "n") == {:stop, :superseded}
    end

    test "disjoint compactions both apply" do
      {:write, first, _} = Compaction.replace(state_with(~w(a b c d)), ~w(a b), "m")
      assert {:write, second, 2} = Compaction.replace(first, ~w(c d), "n")
      assert second.packs == ~w(m n)
    end

    test "lists the output once when it is an input or already listed" do
      assert {:write, %{packs: ~w(a c)}, 2} =
               Compaction.replace(state_with(~w(a b c)), ~w(a b), "a")

      assert {:write, %{packs: ~w(b c)}, 2} =
               Compaction.replace(state_with(~w(a b c)), ~w(a b), "b")

      assert {:write, %{packs: ~w(c m)}, 2} =
               Compaction.replace(state_with(~w(a b c m)), ~w(a b), "m")
    end
  end

  test "pushes compact into one pack holding exactly their objects, and nothing is deleted",
       %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    url = TestServer.url(server, @repo)
    dir = pushes!(url, Path.join(tmp_dir, "a"), 20)
    before = state(server.store)
    assert length(before.packs) == 20
    ids = packed_ids(server.store, before.packs, tmp_dir)

    assert {:ok, %{merged: 20, packs: 1}} = GitServer.compact(opts(server.store, tmp_dir), @repo)
    after_ = state(server.store)
    assert %{after_ | packs: before.packs} == before
    [merged] = after_.packs
    assert packed_ids(server.store, [merged], tmp_dir) == ids
    assert Enum.all?(before.packs, &exists?(server.store, @repo, &1))

    # git's own check of the stored pack.
    pack = Path.join(tmp_dir, "merged.pack")
    {:ok, _} = Store.get_file(server.store, Repository.pack_key(@repo, merged), pack)
    {_, 0} = git(["index-pack", pack], cd: tmp_dir)
    {_, 0} = git(["verify-pack", Path.rootname(pack) <> ".idx"], cd: tmp_dir)

    assert clone!(url, tmp_dir) == rev!(dir, "HEAD")
    Invariant.check!(server.store, @repo, tmp_dir)
    assert GitServer.compact(opts(server.store, tmp_dir), @repo) == {:ok, :unchanged}

    # A small push after a large merged pack is already a progression.
    commit!(dir, "more", "more\n")
    {_, 0} = git(["push", "-q"], cd: dir)
    compact = &GitServer.compact(opts(server.store, tmp_dir), @repo, &1)
    assert compact.(max_packs: 0) == {:ok, :unchanged}
    assert clone!(url, tmp_dir) == rev!(dir, "HEAD")
    assert File.ls!(work_dir(tmp_dir)) == []
  end

  test "only the chosen packs are downloaded, and none when there's nothing to do",
       %{tmp_dir: tmp_dir} do
    inner = GitServer.TestStore.fresh()
    seed_packs!(inner, tmp_dir, 3)
    store = CountingStore.wrap(inner)
    assert GitServer.compact(opts(store, tmp_dir), @repo) == {:ok, :unchanged}
    assert CountingStore.counts(store).get_files == 0

    # One large pack stays out of a merge of the small ones.
    source = Seed.source!(Path.join(tmp_dir, "big"))
    Seed.commit!(source, "big", :crypto.strong_rand_bytes(100_000))
    big = Seed.push_pack_only!(inner, @repo, source, ["--all"])

    assert {:ok, %{merged: 3, packs: 2}} =
             GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 3)

    assert CountingStore.counts(store).get_files == 6
    assert big in state(inner).packs
  end

  test "packs each within the push limits, together over them, compact and clone",
       %{tmp_dir: tmp_dir} do
    limits = [max_pack_bytes: 2000, max_objects: 3]
    server = TestServer.start!(limits)
    url = TestServer.url(server, @repo)
    dir = pushes!(url, Path.join(tmp_dir, "a"), 6)

    assert {:ok, %{merged: 6, packs: 1}} =
             GitServer.compact(opts(server.store, tmp_dir, limits), @repo, max_packs: 0)

    assert clone!(url, tmp_dir) == rev!(dir, "HEAD")
    commit!(dir, "after", "after\n")
    {_, 0} = git(["push", "-q"], cd: dir)
    Invariant.check!(server.store, @repo, tmp_dir)
  end

  test "delta chains inside packs survive", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    source = Seed.source!(Path.join(tmp_dir, "source"))
    lines = for i <- 1..4000, do: "line #{i}: #{Base.encode16(:crypto.strong_rand_bytes(8))}\n"

    for round <- 1..4 do
      for step <- 1..3 do
        edited = List.replace_at(lines, round * 10 + step, "edited #{round} #{step}\n")
        Seed.commit!(source, "big.txt", edited)
      end

      revs = if round == 1, do: ["HEAD"], else: ["HEAD", "^HEAD~3"]
      Seed.push!(store, @repo, source, revs)
    end

    packs = state(store).packs
    total = Enum.sum(Enum.map(packs, &pack_size(store, &1)))
    assert {:ok, %{merged: 4}} = GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0)
    [merged] = state(store).packs
    size = pack_size(store, merged)
    # The 12 versions of a 140 KB file, whole, would be far bigger.
    assert size <= total
    assert size < 12 * 140_000 / 4
    Invariant.check!(store, @repo, tmp_dir)
  end

  defp pack_size(store, name) do
    {:ok, objects} = Store.list(store, Repository.pack_key(@repo, name))
    [%{size: size}] = objects
    size
  end

  test "a duplicated object is kept once, and a delta on the dropped copy is written whole",
       %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    x = :crypto.strong_rand_bytes(5000)
    y = x <> "y"
    a = put_built!(store, [PackBuilder.object(:blob, x)])

    b =
      put_built!(store, [
        PackBuilder.object(:blob, x),
        PackBuilder.ofs_delta(Object.id(:blob, y), 0, copy_delta(x, "y")),
      ])

    list_packs!(store, [a, b])

    assert {:ok, %{merged: 2, packs: 1}} =
             GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0)

    [merged] = state(store).packs
    ids = packed_ids(store, [merged], tmp_dir)
    assert ids == MapSet.new([x, y], &ObjectId.to_hex(Object.id(:blob, &1)))
    Invariant.check!(store, @repo, tmp_dir)
  end

  test "a merge that comes out byte for byte one of its inputs leaves that pack listed",
       %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    x = :crypto.strong_rand_bytes(1000)
    y = :crypto.strong_rand_bytes(1000)
    a = put_built!(store, [PackBuilder.object(:blob, x), PackBuilder.object(:blob, y)])
    # Stored, not compressed, so the two packs' sizes don't form a progression.
    b = put_built!(store, [PackBuilder.object(:blob, y, level: 0)])
    list_packs!(store, [a, b])

    # A request holding the cached files of a, by hard link, while compaction runs.
    cache = [pack_cache_dir: Path.join(tmp_dir, "cache")]
    cache_option = [cache: {cache[:pack_cache_dir], 1_000_000}]
    {:ok, held} = Repository.snapshot(store, @repo, work_dir(tmp_dir), cache_option)
    held_files = for {pack, idx} <- held.packs, path <- [pack, idx], do: path
    before = Map.new(held_files, &{&1, {File.read!(&1), File.stat!(&1).inode}})

    assert {:ok, %{merged: 2, packs: 1}} =
             GitServer.compact(opts(store, tmp_dir, cache), @repo, max_packs: 0)

    assert state(store).packs == [a]
    assert exists?(store, @repo, b)
    assert Map.new(held_files, &{&1, {File.read!(&1), File.stat!(&1).inode}}) == before
    Repository.release(held)
    Invariant.check!(store, @repo, tmp_dir)
  end

  test "a merge that would pass the byte cap leaves out the input that overflowed it",
       %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    x = :crypto.strong_rand_bytes(20_000)
    small = for i <- 1..3, do: put_built!(store, [PackBuilder.object(:blob, "small #{i}")])
    a = put_built!(store, [PackBuilder.object(:blob, x)])

    # Deltas on a duplicate of x: written whole, each as big as x.
    deltas =
      for i <- 1..4,
          do: PackBuilder.ofs_delta(Object.id(:blob, x <> "#{i}"), 0, copy_delta(x, "#{i}"))

    b = put_built!(store, [PackBuilder.object(:blob, x) | deltas])
    # The largest input, which merges fine.
    c = put_built!(store, [PackBuilder.object(:blob, :crypto.strong_rand_bytes(25_000))])
    list_packs!(store, small ++ [a, b, c])
    options = [max_packs: 0, max_compact_bytes: 70_000]
    compact = fn -> GitServer.compact(opts(store, tmp_dir), @repo, options) end

    # b overflows: what came before it merges.
    log = capture_log(fn -> assert {:ok, %{merged: 4, packs: 3}} = compact.() end)
    refute log =~ "compaction"
    assert [_merged, ^b, ^c] = state(store).packs

    # Again b overflows, second of three: the others merge without it.
    log = capture_log(fn -> assert {:ok, %{merged: 2, packs: 2}} = compact.() end)
    refute log =~ "compaction"
    assert [_merged, ^b] = state(store).packs
    Invariant.check!(store, @repo, tmp_dir)

    assert compact.() == {:ok, :unchanged}

    # Just a and b: no two packs merge within the cap.
    put_built!(store, [PackBuilder.object(:blob, x)], "two")
    put_built!(store, [PackBuilder.object(:blob, x) | deltas], "two")
    list_packs!(store, [a, b], "two")

    log =
      capture_log(fn ->
        assert GitServer.compact(opts(store, tmp_dir), "two", options) ==
                 {:error, "compaction stopped: no two packs merge within :max_compact_bytes"}
      end)

    assert log =~ "repository two: compaction stopped"
  end

  test "an input whose idx doesn't match its objects fails and publishes nothing",
       %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    good = put_built!(store, [PackBuilder.object(:blob, "good")])
    lying = %{PackBuilder.object(:blob, "real") | id: Object.id(:blob, "claimed")}
    bad = put_built!(store, [lying])
    list_packs!(store, [good, bad])

    log =
      capture_log(fn ->
        assert {:error, "compaction failed: " <> _} =
                 GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0)
      end)

    assert log =~ "repository #{@repo}: compaction failed"
    assert state(store).packs == [good, bad]
    {:ok, keys} = Store.list(store, "#{@repo}.git/packs/")
    assert length(keys) == 4
  end

  test "options and names are checked", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    assert {:error, "invalid repository name"} = GitServer.compact(opts(store, tmp_dir), "../x")

    assert {:error, "compaction options" <> _} =
             GitServer.compact(opts(store, tmp_dir), @repo, max_packs: -1)

    assert {:error, "compaction options" <> _} =
             GitServer.compact(opts(store, tmp_dir), @repo, nope: 1)

    assert {:error, "unknown GitServer.Plug options" <> _} = GitServer.compact([nope: 1], @repo)
    assert GitServer.compact(opts(store, tmp_dir), "#{@repo}.git") == {:ok, :unchanged}
  end

  test "a second compaction of a repository on this node is busy", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    seed_packs!(store, tmp_dir, 3)
    test = self()

    holder =
      spawn(fn ->
        lock = {{Compaction, Store.describe(store), @repo}, self()}
        true = :global.set_lock(lock, [node()], 0)
        send(test, :locked)
        receive do: (:done -> :ok)
      end)

    assert_receive :locked
    assert GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0) == {:ok, :busy}
    monitor = Process.monitor(holder)
    send(holder, :done)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert {:ok, %{merged: 3}} = GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0)
  end

  test "with the pack cache, a clone after compaction downloads no pack", %{tmp_dir: tmp_dir} do
    store = CountingStore.wrap(GitServer.TestStore.fresh())
    cache = [pack_cache_dir: Path.join(tmp_dir, "cache")]
    server = TestServer.start!([store: store] ++ cache)
    url = TestServer.url(server, @repo)
    pushes!(url, Path.join(tmp_dir, "a"), 3)

    assert {:ok, %{merged: 3}} =
             GitServer.compact(opts(store, tmp_dir, cache), @repo, max_packs: 0)

    CountingStore.reset(store)
    clone!(url, tmp_dir)
    assert CountingStore.counts(store).get_files == 0
  end

  describe "races" do
    test "a push lands between compaction's snapshot and its write", %{tmp_dir: tmp_dir} do
      server = TestServer.start!()
      url = TestServer.url(server, @repo)
      dir = pushes!(url, Path.join(tmp_dir, "a"), 4)
      packs = state(server.store).packs

      store =
        RacingStore.wrap(server.store, fn ->
          commit!(dir, "racing", "racing\n")
          {_, 0} = git(["push", "-q"], cd: dir)
        end)

      assert {:ok, %{merged: 4, packs: 2}} =
               GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0)

      final = state(server.store)
      assert [_merged, pushed] = final.packs
      refute pushed in packs
      assert final.refs["refs/heads/main"] == rev!(dir, "HEAD")
      assert clone!(url, tmp_dir) == rev!(dir, "HEAD")
      Invariant.check!(server.store, @repo, tmp_dir)
    end

    test "a compaction lands between a push's snapshot and its write", %{tmp_dir: tmp_dir} do
      inner = GitServer.TestStore.fresh()
      seed_packs!(inner, tmp_dir, 4)
      test = self()

      store =
        RacingStore.wrap(inner, fn ->
          send(test, {:compacted, GitServer.compact(opts(inner, tmp_dir), @repo, max_packs: 0)})
        end)

      checks = :counters.new(1, [])

      before_update = fn _push ->
        :counters.add(checks, 1, 1)
        :ok
      end

      server = TestServer.start!(store: store, before_update: before_update)
      url = TestServer.url(server, @repo)
      dir = Path.join(tmp_dir, "a")
      {_, 0} = git(["clone", "-q", url, dir])
      head = commit!(dir, "new", "new\n")
      {output, 0} = git(["push", "origin", "HEAD:main"], cd: dir)
      assert output =~ "-> main"
      assert_received {:compacted, {:ok, %{merged: 4, packs: 1}}}
      assert :counters.get(checks, 1) == 2
      assert length(state(inner).packs) == 2
      assert clone!(url, tmp_dir) == head
      Invariant.check!(inner, @repo, tmp_dir)
    end

    test "of two compactions of the same packs, one publishes and the other stops",
         %{tmp_dir: tmp_dir} do
      inner = GitServer.TestStore.fresh()
      seed_packs!(inner, tmp_dir, 3)
      test = self()

      # Another server: a different store, so not this node's lock on the first.
      store =
        RacingStore.wrap(inner, fn ->
          send(test, {:first, GitServer.compact(opts(inner, tmp_dir), @repo, max_packs: 0)})
        end)

      assert GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0) == {:ok, :superseded}
      assert_received {:first, {:ok, %{merged: 3, packs: 1}}}
      assert length(state(inner).packs) == 1
      Invariant.check!(inner, @repo, tmp_dir)
    end

    test "a force push and a branch delete land between compaction's snapshot and its write",
         %{tmp_dir: tmp_dir} do
      server = TestServer.start!()
      url = TestServer.url(server, @repo)
      dir = pushes!(url, Path.join(tmp_dir, "a"), 3)
      {_, 0} = git(["push", "-q", "origin", "HEAD:refs/heads/topic"], cd: dir)

      store =
        RacingStore.wrap(server.store, fn ->
          {_, 0} = git(["commit", "-q", "--amend", "-m", "rewritten"], cd: dir)
          {_, 0} = git(["push", "-q", "--force", "origin", "HEAD:main"], cd: dir)
          {_, 0} = git(["push", "-q", "origin", "--delete", "topic"], cd: dir)
        end)

      ids = packed_ids(server.store, state(server.store).packs, tmp_dir)
      assert {:ok, %{merged: 3}} = GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0)
      assert state(server.store).refs == %{"refs/heads/main" => rev!(dir, "HEAD")}
      # The overwritten commits stay: nothing is pruned.
      assert MapSet.subset?(ids, packed_ids(server.store, state(server.store).packs, tmp_dir))
      assert clone!(url, tmp_dir) == rev!(dir, "HEAD")
      Invariant.check!(server.store, @repo, tmp_dir)
    end

    test "a push from a stale base is still refused after a force push and a compaction",
         %{tmp_dir: tmp_dir} do
      server = TestServer.start!()
      url = TestServer.url(server, @repo)
      a = pushes!(url, Path.join(tmp_dir, "a"), 3)
      b = Path.join(tmp_dir, "b")
      {_, 0} = git(["clone", "-q", url, b])
      commit!(b, "from-b", "b\n")

      # b's push is checked against main as it was, then this lands first.
      racing =
        RacingStore.wrap(server.store, fn ->
          {_, 0} = git(["commit", "-q", "--amend", "-m", "rewritten"], cd: a)
          {_, 0} = git(["push", "-q", "--force"], cd: a)

          {:ok, %{merged: 4}} =
            GitServer.compact(opts(server.store, tmp_dir), @repo, max_packs: 0)
        end)

      b_server = TestServer.start!(store: racing)
      {output, 1} = git(["push", TestServer.url(b_server, @repo), "HEAD:main"], cd: b)
      assert output =~ "fetch first"
      assert state(server.store).refs == %{"refs/heads/main" => rev!(a, "HEAD")}
      Invariant.check!(server.store, @repo, tmp_dir)
    end

    test "a push resending a listed pack that compaction retires re-lists it, still stored",
         %{tmp_dir: tmp_dir} do
      inner = GitServer.TestStore.fresh()
      source = seed_packs!(inner, tmp_dir, 2)
      [first, _] = state(inner).packs
      a = Seed.rev_parse!(source, "HEAD~")

      # The first seeded pack again, byte for byte, with a new ref at its commit.
      bytes = Store.get(inner, Repository.pack_key(@repo, first)) |> elem(1)

      store =
        RacingStore.wrap(inner, fn ->
          {:ok, %{merged: 2}} = GitServer.compact(opts(inner, tmp_dir), @repo, max_packs: 0)
        end)

      plug_opts = GitServer.Plug.init(opts(store, tmp_dir))
      zero = String.duplicate("0", 40)

      body =
        IO.iodata_to_binary([
          GitServer.PktLine.encode("#{zero} #{a} refs/heads/again\0report-status\n"),
          GitServer.PktLine.flush(),
          bytes,
        ])

      conn =
        Plug.Test.conn(:post, "/#{@repo}/git-receive-pack", body)
        |> Plug.Conn.put_req_header("content-type", "application/x-git-receive-pack-request")
        |> GitServer.Plug.call(plug_opts)

      assert conn.resp_body =~ "ok refs/heads/again"
      final = state(inner)
      assert first in final.packs
      assert length(final.packs) == 2
      assert final.refs["refs/heads/again"] == a
      Invariant.check!(inner, @repo, tmp_dir)
    end

    test "a fetch that read the state before a compaction still gets the packs it lists",
         %{tmp_dir: tmp_dir} do
      server = TestServer.start!()
      url = TestServer.url(server, @repo)
      dir = pushes!(url, Path.join(tmp_dir, "a"), 4)
      packs = state(server.store).packs

      # A clone reads state for ls-refs and again for fetch, then downloads.
      test = self()

      store =
        RacingStore.after_read(server.store, 2, fn ->
          result = GitServer.compact(opts(server.store, tmp_dir), @repo, max_packs: 0)
          send(test, {:compacted, result})
        end)

      reader = TestServer.start!(store: store)
      assert clone!(TestServer.url(reader, @repo), tmp_dir) == rev!(dir, "HEAD")
      assert_received {:compacted, {:ok, %{merged: 4}}}
      assert length(state(server.store).packs) == 1
      assert Enum.all?(packs, &exists?(server.store, @repo, &1))
    end

    test "a compaction that keeps losing until its deadline publishes nothing",
         %{tmp_dir: tmp_dir} do
      inner = GitServer.TestStore.fresh()
      seed_packs!(inner, tmp_dir, 3)
      before = state(inner)
      store = OutageStore.wrap(inner, [:put], ~r{/state$}, :precondition_failed)

      assert {:error, "compaction lost the race" <> _} =
               GitServer.compact(opts(store, tmp_dir, push_deadline_ms: 0), @repo, max_packs: 0)

      assert state(inner) == before
      Invariant.check!(inner, @repo, tmp_dir)
    end

    test "a failed upload or state write publishes nothing", %{tmp_dir: tmp_dir} do
      inner = GitServer.TestStore.fresh()
      seed_packs!(inner, tmp_dir, 3)
      before = state(inner)

      for suffix <- [".pack", ".idx", "/state"] do
        store = FailingStore.wrap(inner, suffix, 1)

        assert {:error, "injected failure"} =
                 GitServer.compact(opts(store, tmp_dir), @repo, max_packs: 0)

        assert state(inner) == before
      end

      Invariant.check!(inner, @repo, tmp_dir)
    end
  end

  @tag timeout: 120_000
  test "pushes, compactions and clones running together", %{tmp_dir: tmp_dir} do
    server = TestServer.start!(store: CountingStore.wrap(GitServer.TestStore.fresh()))
    url = TestServer.url(server, @repo)
    pushes!(url, Path.join(tmp_dir, "seed"), 1)
    deadline = System.monotonic_time(:millisecond) + @stress_ms
    running? = fn -> System.monotonic_time(:millisecond) < deadline end

    pushers =
      for n <- 1..3 do
        Task.async(fn ->
          dir = Path.join(tmp_dir, "pusher-#{n}")
          {_, 0} = git(["clone", "-q", url, dir])
          {_, 0} = git(["checkout", "-q", "-b", "b#{n}"], cd: dir)

          Stream.iterate(1, &(&1 + 1))
          |> Enum.reduce_while(nil, fn i, last ->
            if running?.() do
              head = commit!(dir, "f#{n}", "#{n} #{i}\n")
              {_, status} = git(["push", "-q", "origin", "b#{n}"], cd: dir)
              {:cont, if(status == 0, do: head, else: last)}
            else
              {:halt, {"refs/heads/b#{n}", last}}
            end
          end)
        end)
      end

    compactor =
      Task.async(fn ->
        Stream.repeatedly(fn ->
          GitServer.compact(opts(server.store, tmp_dir), @repo, max_packs: 2)
        end)
        |> Enum.take_while(fn result ->
          assert match?({:ok, _}, result), inspect(result)
          running?.()
        end)
        |> Enum.count(&match?({:ok, %{merged: _}}, &1))
      end)

    cloner =
      Task.async(fn ->
        Stream.repeatedly(fn -> clone!(url, tmp_dir) end)
        |> Enum.take_while(fn _ -> running?.() end)
        |> length()
      end)

    landed = Task.await_many(pushers, 60_000)
    assert Task.await(compactor, 60_000) > 0
    assert Task.await(cloner, 60_000) > 0
    final = Invariant.check!(server.store, @repo, tmp_dir)
    for {ref, head} <- landed, do: assert(final.refs[ref] == head)
    clone!(url, tmp_dir)
    assert CountingStore.counts(server.store).deletes == 0
  end
end
