defmodule GitServer.RepositoryTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias GitServer.{Repository, State, Store}

  @a String.duplicate("a", 40)
  @b String.duplicate("b", 40)

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
end
