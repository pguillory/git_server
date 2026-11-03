defmodule GitServer.RepositoryTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias GitServer.{Repository, State, Store}

  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)

  defmodule GateStore do
    @moduledoc """
    Delegates to another store, but holds every download: it writes a few bytes of it,
    sends `{:held, pid, key}` to `owner` and waits for `:go` (download the file) or
    `:fail` (return an error).
    """
    @behaviour GitServer.Store
    alias GitServer.Store

    def wrap(store, owner), do: {__MODULE__, %{inner: store, owner: owner}}

    @impl true
    def get_file(config, key, path) do
      File.write!(path, "part")
      send(config.owner, {:held, self(), key})

      receive do
        :go ->
          File.rm!(path)
          Store.get_file(config.inner, key, path)

        :fail ->
          {:error, "injected failure"}
      end
    end

    @impl true
    def get(config, key), do: Store.get(config.inner, key)
    @impl true
    def put(config, key, body, condition), do: Store.put(config.inner, key, body, condition)
    @impl true
    def put_file(config, key, path, condition),
      do: Store.put_file(config.inner, key, path, condition)

    @impl true
    def delete(config, key), do: Store.delete(config.inner, key)
    @impl true
    def list(config, prefix), do: Store.list(config.inner, prefix)
    @impl true
    def describe(config), do: "gate " <> Store.describe(config.inner)
  end

  defmodule RaisingStore do
    @moduledoc "Delegates to another store, raising on every download."
    @behaviour GitServer.Store
    alias GitServer.Store

    def wrap(store), do: {__MODULE__, store}

    @impl true
    def get_file(_inner, _key, _path), do: raise("boom")
    @impl true
    def get(inner, key), do: Store.get(inner, key)
    @impl true
    def put(inner, key, body, condition), do: Store.put(inner, key, body, condition)
    @impl true
    def put_file(inner, key, path, condition), do: Store.put_file(inner, key, path, condition)
    @impl true
    def delete(inner, key), do: Store.delete(inner, key)
    @impl true
    def list(inner, prefix), do: Store.list(inner, prefix)
    @impl true
    def describe(inner), do: "raising " <> Store.describe(inner)
  end

  test "state reads and conditional writes" do
    store = GitServer.TestStore.fresh()
    assert Repository.read_state(store, "r") == {:ok, State.new(), :absent}

    state = %State{refs: %{"refs/heads/main" => @a}}
    assert {:ok, e1} = Repository.put_state(store, "r", state, :absent)
    assert Repository.put_state(store, "r", state, :absent) == {:error, :precondition_failed}
    assert Repository.read_state(store, "r") == {:ok, state, e1}
    assert {:ok, e2} = Repository.put_state(store, "r", %{state | packs: [@a]}, e1)
    assert Repository.put_state(store, "r", state, e1) == {:error, :precondition_failed}
    assert {:ok, %State{packs: [@a]}, ^e2} = Repository.read_state(store, "r")
    assert {:ok, [%{key: "r.git/state"}]} = Store.list(store, "")

    {:ok, _} = Store.put(store, Repository.state_key("bad"), "garbage", :none)

    assert {:error, "repository bad: not a git_server state object"} =
             Repository.read_state(store, "bad")
  end

  @tag :tmp_dir
  test "snapshots download the listed packs, refresh adds new ones, release deletes them", %{
    tmp_dir: tmp_dir,
  } do
    store = GitServer.TestStore.fresh()

    assert {:ok, empty} = Repository.snapshot(store, "r", tmp_dir)
    assert {empty.etag, empty.packs, File.ls!(empty.dir)} == {:absent, [], []}
    Repository.release(empty)
    assert File.ls!(tmp_dir) == []

    for name <- [@a, @b] do
      {:ok, _} = Store.put(store, Repository.pack_key("r", name), "pack #{name}", :none)
      {:ok, _} = Store.put(store, Repository.idx_key("r", name), "idx #{name}", :none)
    end

    {:ok, e1} = Repository.put_state(store, "r", %State{packs: [@a]}, :absent)
    assert {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir)
    assert snapshot.etag == e1
    assert (File.stat!(snapshot.dir).mode &&& 0o777) == 0o700
    assert [{pack, idx}] = snapshot.packs
    assert {File.read!(pack), File.read!(idx)} == {"pack #{@a}", "idx #{@a}"}

    {:ok, e2} = Repository.put_state(store, "r", %State{packs: [@a, @b]}, e1)
    assert {:ok, refreshed} = Repository.refresh(snapshot)
    assert refreshed.etag == e2
    assert [{^pack, ^idx}, {pack_b, _}] = refreshed.packs
    assert File.read!(pack_b) == "pack #{@b}"

    assert Repository.release(refreshed) == :ok
    assert File.ls!(tmp_dir) == []
  end

  defp put_packs!(store, names) do
    for name <- names do
      {:ok, _} = Store.put(store, Repository.pack_key("r", name), "pack #{name}", :none)
      {:ok, _} = Store.put(store, Repository.idx_key("r", name), "idx #{name}", :none)
    end
  end

  defp names(n), do: for(i <- 1..n, do: Base.encode16(<<i::160>>, case: :lower))

  defp read_packs(snapshot),
    do: for({pack, idx} <- snapshot.packs, do: {File.read!(pack), File.read!(idx)})

  defp contents(names), do: for(name <- names, do: {"pack #{name}", "idx #{name}"})

  @tag :tmp_dir
  test "downloads a few files at a time, keeping the state's order", %{tmp_dir: tmp_dir} do
    inner = GitServer.TestStore.fresh()
    names = names(6)
    put_packs!(inner, names)
    {:ok, _} = Repository.put_state(inner, "r", %State{packs: names}, :absent)
    store = GateStore.wrap(inner, self())

    task = Task.async(fn -> Repository.snapshot(store, "r", tmp_dir, concurrency: 3) end)

    held = for _ <- 1..3, do: assert_receive({:held, _, _}, 10_000)
    refute_receive {:held, _, _}, 100

    # Then let every download through.
    for {:held, pid, _} <- held, do: send(pid, :go)

    for _ <- 1..9 do
      assert_receive {:held, pid, _}, 10_000
      send(pid, :go)
    end

    refute_receive {:held, _, _}, 50

    {:ok, snapshot} = Task.await(task)
    assert read_packs(snapshot) == contents(names)
    Repository.release(snapshot)
  end

  @tag :tmp_dir
  test "a failed download stops the others and leaves no partial file", %{tmp_dir: tmp_dir} do
    inner = GitServer.TestStore.fresh()
    [first | _] = names = names(5)
    put_packs!(inner, names)
    {:ok, e1} = Repository.put_state(inner, "r", %State{packs: [first]}, :absent)
    {:ok, snapshot} = Repository.snapshot(inner, "r", tmp_dir)
    {:ok, _} = Repository.put_state(inner, "r", %State{packs: names}, e1)

    gated = %{snapshot | store: GateStore.wrap(inner, self()), concurrency: 3}
    task = Task.async(fn -> Repository.refresh(gated) end)
    held = for _ <- 1..3, do: assert_receive({:held, _, _}, 10_000)
    [{failing, _} | others] = for {:held, pid, key} <- held, do: {pid, key}
    monitors = for {pid, _} <- others, do: Process.monitor(pid)

    send(failing, :fail)
    assert Task.await(task) == {:error, "injected failure"}
    for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _, _}, 10_000)
    refute_received {:held, _, _}

    # The stopped downloads left their bytes only under temporary names.
    assert Enum.sort(File.ls!(snapshot.dir)) ==
             Enum.sort(
               ["#{first}.pack", "#{first}.idx"] ++
                 for({:held, _, key} <- held, do: Path.basename(key) <> ".part")
             )

    {:ok, refreshed} = Repository.refresh(snapshot)
    assert read_packs(refreshed) == contents(names)
    Repository.release(refreshed)
  end

  @tag :tmp_dir
  test "a download that raises fails the snapshot and leaves nothing behind", %{
    tmp_dir: tmp_dir,
  } do
    inner = GitServer.TestStore.fresh()
    put_packs!(inner, names(3))
    {:ok, _} = Repository.put_state(inner, "r", %State{packs: names(3)}, :absent)

    assert {:error, "the store download raised RuntimeError\n" <> _} =
             Repository.snapshot(RaisingStore.wrap(inner), "r", tmp_dir)

    assert File.ls!(tmp_dir) == []
  end

  @tag :tmp_dir
  test "a missing pack fails the snapshot and leaves nothing behind", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    {:ok, _} = Repository.put_state(store, "r", %State{packs: [@a]}, :absent)

    assert Repository.snapshot(store, "r", tmp_dir) ==
             {:error, "repository r: pack #{@a} is missing"}

    assert File.ls!(tmp_dir) == []

    assert Repository.with_snapshot(store, "empty", tmp_dir, fn snapshot -> snapshot.etag end) ==
             :absent

    assert_raise RuntimeError, fn ->
      Repository.with_snapshot(store, "empty", tmp_dir, fn _ -> raise "boom" end)
    end

    assert File.ls!(tmp_dir) == []
  end

  @tag :tmp_dir
  test "update writes against the fresh state after a lost race, stops, or gives up at the deadline",
       %{tmp_dir: tmp_dir} do
    inner = GitServer.TestStore.fresh()
    {:ok, e1} = Repository.put_state(inner, "r", %State{refs: %{"refs/heads/a" => @a}}, :absent)

    # Another writer wins the race just before the first conditional write.
    store =
      GitServer.RacingStore.wrap(inner, fn ->
        {:ok, _} =
          Repository.put_state(inner, "r", %State{refs: %{"refs/heads/b" => @b}}, e1)
      end)

    deadline = System.monotonic_time(:millisecond) + 10_000

    add_c = fn snapshot, last ->
      refs = Map.put(snapshot.state.refs, "refs/heads/c", @a)
      {:write, %{snapshot.state | refs: refs}, [map_size(snapshot.state.refs) | last || []]}
    end

    {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir)
    # The second call saw the first's result and the other writer's ref.
    assert Repository.update(snapshot, deadline, add_c) == {:ok, [1, 1]}

    assert {:ok, %State{refs: %{"refs/heads/b" => @b, "refs/heads/c" => @a} = refs}, _} =
             Repository.read_state(inner, "r")

    assert map_size(refs) == 2
    Repository.release(snapshot)

    {:ok, snapshot} = Repository.snapshot(inner, "r", tmp_dir)
    assert Repository.update(snapshot, deadline, fn _, nil -> {:stop, :no} end) == {:stop, :no}

    # A stale snapshot past its deadline loses once and gives up.
    {:ok, _} = Repository.put_state(inner, "r", State.new(), snapshot.etag)
    past = System.monotonic_time(:millisecond)
    write = fn snapshot, _last -> {:write, snapshot.state, :tried} end
    assert Repository.update(snapshot, past, write) == {:error, :deadline, :tried}
    Repository.release(snapshot)
  end

  @tag :tmp_dir
  test "update gives the store's reason when a write fails", %{tmp_dir: tmp_dir} do
    store = GitServer.FailingStore.wrap(GitServer.TestStore.fresh(), "/state", 1)
    {:ok, snapshot} = Repository.snapshot(store, "r", tmp_dir)
    write = fn snapshot, _last -> {:write, snapshot.state, :tried} end
    deadline = System.monotonic_time(:millisecond) + 10_000
    assert Repository.update(snapshot, deadline, write) == {:error, "injected failure", :tried}
    assert Repository.update(snapshot, deadline, write) == {:ok, :tried}
    Repository.release(snapshot)
  end
end
