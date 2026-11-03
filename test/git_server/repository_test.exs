defmodule GitServer.RepositoryTest do
  use ExUnit.Case, async: true
  import GitServer.Repository
  import Bitwise
  alias GitServer.State
  alias GitServer.Store

  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)

  defmodule GateStore do
    @moduledoc """
    Delegates to another store, but holds every download: it writes a few bytes of it,
    sends `{:held, pid, key}` to `owner` and waits for `:go`, then downloads the file.
    """
    @behaviour GitServer.Store
    alias GitServer.Store

    def wrap(store, owner) do
      {__MODULE__, %{inner: store, owner: owner}}
    end

    @impl true
    def get_file(config, key, path) do
      File.write!(path, "part")
      send(config.owner, {:held, self(), key})

      receive do
        :go ->
          File.rm!(path)
          Store.get_file(config.inner, key, path)
      end
    end

    @impl true
    def get(config, key) do
      Store.get(config.inner, key)
    end

    @impl true
    def put(config, key, body, condition) do
      Store.put(config.inner, key, body, condition)
    end

    @impl true
    def put_file(config, key, path, condition) do
      Store.put_file(config.inner, key, path, condition)
    end

    @impl true
    def delete(config, key) do
      Store.delete(config.inner, key)
    end

    @impl true
    def list(config, prefix) do
      Store.list(config.inner, prefix)
    end

    @impl true
    def describe(config) do
      "gate " <> Store.describe(config.inner)
    end
  end

  test "state reads and conditional writes" do
    store = GitServer.TestStore.fresh()
    assert read_state(store, "r") == {:ok, State.new(), :absent}

    state = %State{refs: %{"refs/heads/main" => @a}}
    assert {:ok, e1} = put_state(store, "r", state, :absent)
    assert put_state(store, "r", state, :absent) == {:error, :precondition_failed}
    assert read_state(store, "r") == {:ok, state, e1}
    assert {:ok, e2} = put_state(store, "r", %{state | packs: [@a]}, e1)
    assert put_state(store, "r", state, e1) == {:error, :precondition_failed}
    assert {:ok, %State{packs: [@a]}, ^e2} = read_state(store, "r")
    assert {:ok, [%{key: "r.git/state"}]} = Store.list(store, "")

    {:ok, _} = Store.put(store, state_key("bad"), "garbage", :none)

    assert {:error, "repository bad: not a git_server state object"} =
             read_state(store, "bad")
  end

  @tag :tmp_dir
  test "snapshots download the listed packs, refresh adds new ones, release deletes them", %{
    tmp_dir: tmp_dir,
  } do
    store = GitServer.TestStore.fresh()

    assert {:ok, empty} = snapshot(store, "r", tmp_dir)
    assert {empty.etag, empty.packs, File.ls!(empty.dir)} == {:absent, [], []}
    release(empty)
    assert File.ls!(tmp_dir) == []

    for name <- [@a, @b] do
      {:ok, _} = Store.put(store, pack_key("r", name), "pack #{name}", :none)
      {:ok, _} = Store.put(store, idx_key("r", name), "idx #{name}", :none)
    end

    {:ok, e1} = put_state(store, "r", %State{packs: [@a]}, :absent)
    assert {:ok, snapshot} = snapshot(store, "r", tmp_dir)
    assert snapshot.etag == e1
    assert (File.stat!(snapshot.dir).mode &&& 0o777) == 0o700
    assert [{pack, idx}] = snapshot.packs
    assert {File.read!(pack), File.read!(idx)} == {"pack #{@a}", "idx #{@a}"}

    {:ok, e2} = put_state(store, "r", %State{packs: [@a, @b]}, e1)
    assert {:ok, refreshed} = refresh(snapshot)
    assert refreshed.etag == e2
    assert [{^pack, ^idx}, {pack_b, _}] = refreshed.packs
    assert File.read!(pack_b) == "pack #{@b}"

    assert release(refreshed) == :ok
    assert File.ls!(tmp_dir) == []
  end

  defp put_packs!(store, names) do
    for name <- names do
      {:ok, _} = Store.put(store, pack_key("r", name), "pack #{name}", :none)
      {:ok, _} = Store.put(store, idx_key("r", name), "idx #{name}", :none)
    end
  end

  defp names(n) do
    for(i <- 1..n, do: Base.encode16(<<i::160>>, case: :lower))
  end

  defp read_packs(snapshot) do
    for({pack, idx} <- snapshot.packs, do: {File.read!(pack), File.read!(idx)})
  end

  defp contents(names) do
    for(name <- names, do: {"pack #{name}", "idx #{name}"})
  end

  @tag :tmp_dir
  test "downloads a few files at a time, keeping the state's order", %{tmp_dir: tmp_dir} do
    inner = GitServer.TestStore.fresh()
    names = names(6)
    put_packs!(inner, names)
    {:ok, _} = put_state(inner, "r", %State{packs: names}, :absent)
    store = GateStore.wrap(inner, self())

    task = Task.async(fn -> snapshot(store, "r", tmp_dir, concurrency: 3) end)

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
    release(snapshot)
  end

  @tag :tmp_dir
  test "a missing pack fails the snapshot and leaves nothing behind", %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    {:ok, _} = put_state(store, "r", %State{packs: [@a]}, :absent)

    assert snapshot(store, "r", tmp_dir) ==
             {:error, "repository r: pack #{@a} is missing"}

    assert File.ls!(tmp_dir) == []

    assert with_snapshot(store, "empty", tmp_dir, fn snapshot -> snapshot.etag end) ==
             :absent

    assert_raise RuntimeError, fn ->
      with_snapshot(store, "empty", tmp_dir, fn _ -> raise "boom" end)
    end

    assert File.ls!(tmp_dir) == []
  end

  @tag :tmp_dir
  test "update writes against the fresh state after a lost race, stops, or gives up at the deadline",
       %{tmp_dir: tmp_dir} do
    inner = GitServer.TestStore.fresh()
    {:ok, e1} = put_state(inner, "r", %State{refs: %{"refs/heads/a" => @a}}, :absent)

    # Another writer wins the race just before the first conditional write.
    store =
      GitServer.RacingStore.wrap(inner, fn ->
        {:ok, _} =
          put_state(inner, "r", %State{refs: %{"refs/heads/b" => @b}}, e1)
      end)

    deadline = System.monotonic_time(:millisecond) + 10_000

    add_c = fn snapshot, last ->
      refs = Map.put(snapshot.state.refs, "refs/heads/c", @a)
      {:write, %{snapshot.state | refs: refs}, [map_size(snapshot.state.refs) | last || []]}
    end

    {:ok, snapshot} = snapshot(store, "r", tmp_dir)
    # The second call saw the first's result and the other writer's ref.
    assert update(snapshot, deadline, add_c) == {:ok, [1, 1]}

    assert {:ok, %State{refs: %{"refs/heads/b" => @b, "refs/heads/c" => @a} = refs}, _} =
             read_state(inner, "r")

    assert map_size(refs) == 2
    release(snapshot)

    {:ok, snapshot} = snapshot(inner, "r", tmp_dir)
    assert update(snapshot, deadline, fn _, nil -> {:stop, :no} end) == {:stop, :no}

    # A stale snapshot past its deadline loses once and gives up.
    {:ok, _} = put_state(inner, "r", State.new(), snapshot.etag)
    past = System.monotonic_time(:millisecond)
    write = fn snapshot, _last -> {:write, snapshot.state, :tried} end
    assert update(snapshot, past, write) == {:error, :deadline, :tried}
    release(snapshot)
  end
end
