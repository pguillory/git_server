defmodule GitServer.Invariant do
  @moduledoc """
  Checks a repository in the store is whole: every pack and idx its state lists
  exists, every object in those packs reads and has everything it refers to there
  with the right type, and every ref names an object there.
  """

  import ExUnit.Assertions
  alias GitServer.Object
  alias GitServer.ObjectDB
  alias GitServer.ObjectId
  alias GitServer.Repository
  alias GitServer.Pack.Idx

  def check!(store, repo, tmp_dir) do
    # The snapshot fails if a listed pack or idx is missing.
    {:ok, snapshot} = Repository.snapshot(store, repo, tmp_dir)

    try do
      {:ok, db} = ObjectDB.open(snapshot.packs)

      try do
        ids =
          snapshot.packs
          |> Enum.flat_map(fn {_pack, idx_path} ->
            {:ok, idx} = Idx.decode(File.read!(idx_path))
            Enum.map(Idx.entries(idx), &elem(&1, 0))
          end)
          |> Enum.uniq()

        for id <- ids do
          assert {:ok, type, content} = ObjectDB.read(db, id)
          assert {:ok, links} = Object.parse_links(type, content)

          for {link_type, link} <- links do
            assert {:ok, ^link_type, _size} = ObjectDB.lookup(db, link),
                   "#{ObjectId.to_hex(id)} lacks its #{link_type} #{ObjectId.to_hex(link)}"
          end
        end

        for {ref, hex} <- snapshot.state.refs do
          {:ok, id} = ObjectId.from_hex(hex)
          assert {:ok, _type, _size} = ObjectDB.lookup(db, id), "#{ref} names a missing object"
        end

        snapshot.state
      after
        ObjectDB.close(db)
      end
    after
      Repository.release(snapshot)
    end
  end
end
