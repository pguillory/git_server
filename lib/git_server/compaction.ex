defmodule GitServer.Compaction do
  @moduledoc """
  Merges a repository's small packs into one, keeping every object, so the number of
  packs a fetch or push downloads stays logarithmic in the number of pushes. See
  `GitServer.compact/3`.

  It deletes nothing. The merged packs are retired: no longer listed, still in the
  store. The new pack is visible only through the same conditional state write as a
  push (`GitServer.Repository.update/3`), made only if every merged pack is still
  listed, and only after the new pack has been indexed in full and found to hold
  exactly the merged packs' objects. So every state's packs hold every object any
  earlier state's did, and a push that loses its race to a compaction, or a reader
  of an older state, finds everything it needs.

  The check compares the new pack's objects, each hashed from its content, with the
  ids its inputs' idx files list. That proves the new pack holds what readers of the
  inputs could find, given idx files this library wrote itself when the packs came in
  (a push's indexer, or a compaction's): an idx naming an object its pack doesn't
  hold fails the check, unless that entry is a duplicate the merge drops.

  Two places may list a pack a fresh state no longer lists, which is safe only because
  nothing is deleted (a future garbage collector must check both again on every
  attempt): a push resending a pack the state listed, which it doesn't store again,
  after a compaction merged it; and a merged pack identical to one listed when the
  compaction started, which it doesn't store again either.
  """

  require Logger

  alias GitServer.{Config, ObjectId, PackCache, RepoName, Repository, Store}
  alias GitServer.Pack.{Idx, Indexer, Merge}

  @defaults [max_packs: 8, max_compact_bytes: 1_000_000_000, max_compact_objects: 500_000]

  @doc false
  def run(opts, repo, compact_opts) do
    with :ok <- check_options(compact_opts),
         {:ok, config} <- Config.resolve(opts),
         {:ok, repo} <- canonical(repo) do
      # One compaction of a repository at a time on this node; more would only race.
      lock = {{__MODULE__, Store.describe(config.store), repo}, self()}

      if :global.set_lock(lock, [node()], 0) do
        try do
          locked(config, repo, Keyword.merge(@defaults, compact_opts))
        after
          :global.del_lock(lock, [node()])
        end
      else
        {:ok, :busy}
      end
    end
  end

  defp locked(config, repo, opts) do
    with {:ok, state, _etag} <- Repository.read_state(config.store, repo) do
      if length(state.packs) <= opts[:max_packs] do
        {:ok, :unchanged}
      else
        with {:ok, sizes} <- sizes(config.store, repo, state.packs) do
          case choose(sizes, opts) do
            [] ->
              {:ok, :unchanged}

            chosen ->
              Repository.with_snapshot(
                config.store,
                repo,
                config.temp_dir,
                Config.snapshot_options(config) ++ [only: chosen],
                &compact(config, &1, chosen, opts)
              )
          end
        end
      end
    end
  end

  defp check_options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- Keyword.keys(@defaults) == [] and
         Enum.all?(Keyword.values(opts), &(is_integer(&1) and &1 >= 0)),
       do: :ok,
       else:
         {:error,
          "compaction options are :max_packs, :max_compact_bytes and :max_compact_objects, " <>
            "non-negative integers"}
  end

  defp canonical(repo) do
    case RepoName.canonical(repo) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, "invalid repository name"}
    end
  end

  # Each listed pack's size and object count, from one listing of the packs, so a
  # repository with nothing to merge downloads nothing.
  defp sizes(store, repo, packs) do
    prefix = RepoName.key_prefix(repo) <> "packs/"

    with {:ok, objects} <- Store.list(store, prefix) do
      sizes = Map.new(objects, &{String.replace_prefix(&1.key, prefix, ""), &1.size})

      Enum.reduce_while(packs, {:ok, []}, fn name, {:ok, acc} ->
        with {:ok, bytes} <- Map.fetch(sizes, name <> ".pack"),
             {:ok, idx_bytes} <- Map.fetch(sizes, name <> ".idx") do
          objects = Idx.max_count(idx_bytes)
          {:cont, {:ok, [{name, bytes, objects} | acc]}}
        else
          :error -> {:halt, {:error, "repository #{repo}: pack #{name} is missing"}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  # The snapshot has only the chosen packs; if one is gone, another compaction got
  # there first.
  defp compact(config, snapshot, chosen, opts) do
    if length(snapshot.packs) != length(chosen) do
      {:ok, :superseded}
    else
      inputs = Enum.zip(Enum.filter(snapshot.state.packs, &(&1 in chosen)), snapshot.packs)

      with {:ok, merged} <- merge(config, snapshot, inputs, opts, :first),
           :ok <- store(config, snapshot, merged) do
        publish(config, snapshot, merged)
      end
    end
  end

  @doc """
  The packs to merge, from `sizes`, a list of `{name, bytes, objects}`: none while
  there are at most `:max_packs`; otherwise the small packs `git repack
  --geometric=2` would roll up, so that every pack left is at least twice the size of
  the next smaller, less the largest of them while their total is over
  `:max_compact_bytes` or `:max_compact_objects`, and none if fewer than two are
  left.
  """
  def choose(sizes, opts) do
    opts = Keyword.merge(@defaults, opts)

    if length(sizes) <= opts[:max_packs] do
      []
    else
      sorted =
        sizes |> Enum.with_index() |> Enum.sort_by(fn {{_name, bytes, _}, i} -> {bytes, i} end)

      weights = Enum.map(sorted, fn {{_name, bytes, _}, _i} -> bytes end)
      split = roll_up(weights, geometric_split(weights))

      chosen =
        sorted
        |> Enum.take(split)
        |> Enum.map(&elem(&1, 0))
        |> cap(opts[:max_compact_bytes], opts[:max_compact_objects])

      if length(chosen) >= 2, do: Enum.map(chosen, &elem(&1, 0)), else: []
    end
  end

  # From the largest down, the first pair where the larger is under twice the smaller:
  # the progression starts just above it.
  defp geometric_split(weights) do
    pairs = weights |> Enum.chunk_every(2, 1, :discard) |> Enum.with_index(1) |> Enum.reverse()

    case Enum.find(pairs, fn {[smaller, larger], _i} -> larger < 2 * smaller end) do
      {_pair, i} -> i + 1
      nil -> 0
    end
  end

  # A pack above the split joins while it is under twice everything below it.
  defp roll_up(weights, split) do
    {below, above} = Enum.split(weights, split)

    {split, _total} =
      Enum.reduce_while(above, {split, Enum.sum(below)}, fn weight, {split, total} ->
        if weight < 2 * total,
          do: {:cont, {split + 1, total + weight}},
          else: {:halt, {split, total}}
      end)

    split
  end

  # Without the largest, while over either cap. Sorted smallest first.
  defp cap(chosen, max_bytes, max_objects) do
    if Enum.sum(Enum.map(chosen, &elem(&1, 1))) > max_bytes or
         Enum.sum(Enum.map(chosen, &elem(&1, 2))) > max_objects,
       do: cap(Enum.drop(chosen, -1), max_bytes, max_objects),
       else: chosen
  end

  # The merged pack, indexed in full and checked to hold exactly the inputs' objects,
  # in the snapshot's directory, with its idx: `%{inputs: names, name: name, pack:
  # path, idx: path}`.
  #
  # Objects written whole can make it larger than its inputs. Past the byte cap, it is
  # the `n`th input that overflowed, and an input's entries depend only on the inputs
  # before it, so the first `n` merge within the cap; if fewer than two are before it,
  # it's merged once more without the input that overflowed. So the same inputs don't
  # cost a run of failed merges on every call.
  defp merge(config, snapshot, inputs, opts, attempt) do
    merged = Path.join(snapshot.dir, "merged.pack")
    read_options = Config.read_options(config, snapshot.repo)
    paths = Enum.map(inputs, &elem(&1, 1))

    result =
      with {:ok, checksum, ids} <-
             Merge.write(paths, merged, read_options, opts[:max_compact_bytes]),
           {:ok, indexed} <- Indexer.index(merged, index_limits(config, merged, ids)),
           :ok <- same_objects(indexed, checksum, ids) do
        # Under names of its own: the merge can come out identical to an input,
        # whose files in the snapshot may be hard links into the pack cache.
        idx_path = Path.join(snapshot.dir, "merged.idx")

        case File.write(idx_path, indexed.idx) do
          :ok ->
            names = Enum.map(inputs, &elem(&1, 0))
            {:ok, %{inputs: names, name: ObjectId.to_hex(checksum), pack: merged, idx: idx_path}}

          {:error, posix} ->
            {:error, :io, "cannot write the merged pack: #{:file.format_error(posix)}"}
        end
      end

    case result do
      {:ok, _merged} -> :ok
      _error -> File.rm(merged)
    end

    case result do
      {:ok, _merged} ->
        result

      {:error, :io, reason} ->
        {:error, reason}

      {:error, {:too_large, n}} when n >= 2 ->
        merge(config, snapshot, Enum.take(inputs, n), opts, attempt)

      {:error, {:too_large, n}} when attempt == :first and length(inputs) > 2 ->
        merge(config, snapshot, List.delete_at(inputs, n), opts, :again)

      {:error, {:too_large, _n}} ->
        reason = "no two packs merge within :max_compact_bytes"
        Logger.warning("git_server: repository #{snapshot.repo}: compaction stopped: #{reason}")
        {:error, "compaction stopped: #{reason}"}

      # A stored pack that can't be read or merged whole is corrupt, or this is a bug.
      {:error, reason} ->
        Logger.error("git_server: repository #{snapshot.repo}: compaction failed: #{reason}")
        {:error, "compaction failed: #{reason}"}
    end
  end

  # The inputs met the object and delta limits when they were stored, and the merge
  # makes no chain deeper. The pack's size and count are its own. Its work has no
  # budget of its own: every chain in the output is a chain of one input, and the
  # inputs' entries stay together in their order, so indexing it costs about what
  # indexing the inputs did, and by induction about what indexing the pushes folded
  # into it did, each within the push's budget. A budget from the output's size would
  # refuse, on every call, inputs such as small pushes of large compressible files.
  defp index_limits(config, merged, ids) do
    [
      max_pack_bytes: File.stat!(merged).size,
      max_objects: MapSet.size(ids),
      max_object_bytes: config.max_object_bytes,
      max_delta_depth: config.max_delta_depth,
      max_work_bytes: nil,
      links: false,
    ]
  end

  # An id is the hash of an object's type and content, so the same ids are the same
  # objects.
  defp same_objects(indexed, checksum, ids) do
    cond do
      indexed.checksum != checksum ->
        {:error, "merged pack checksum mismatch"}

      map_size(indexed.objects) != MapSet.size(ids) ->
        {:error, "merged pack lost objects"}

      not Enum.all?(Map.keys(indexed.objects), &MapSet.member?(ids, &1)) ->
        {:error, "merged pack holds objects the inputs don't"}

      true ->
        :ok
    end
  end

  # A pack the state already lists is stored already.
  defp store(config, snapshot, merged) do
    if merged.name in snapshot.state.packs do
      :ok
    else
      with {:ok, idx} <- File.read(merged.idx) do
        Repository.put_pack(config.store, snapshot.repo, merged.name, merged.pack, idx)
      end
    end
  end

  # Replaces the inputs with the merged pack, against each fresh state, only while
  # every input is still listed.
  defp publish(config, snapshot, merged) do
    deadline = System.monotonic_time(:millisecond) + config.push_deadline_ms
    replace = fn snapshot, _last -> replace(snapshot.state, merged.inputs, merged.name) end

    case Repository.update(snapshot, deadline, replace) do
      {:ok, packs} ->
        cache(snapshot, merged)
        {:ok, %{merged: length(merged.inputs), packs: packs}}

      {:stop, :superseded} ->
        {:ok, :superseded}

      {:error, :deadline, _packs} ->
        {:error, "compaction lost the race to other writers until its deadline"}

      {:error, reason, _packs} ->
        {:error, reason}
    end
  end

  @doc false
  # The state with `inputs` replaced by `name` at the first input's place, or
  # `{:stop, :superseded}` if any input is gone. Head and refs stay as they are.
  def replace(state, inputs, name) do
    if Enum.all?(inputs, &(&1 in state.packs)) do
      # The merged pack can be byte for byte one of its inputs (a later input holding
      # only objects an earlier one has), or already listed; it stays listed once.
      gone = List.delete(inputs, name)
      [first | _] = Enum.filter(state.packs, &(&1 in inputs))
      listed? = name in state.packs

      packs =
        Enum.flat_map(state.packs, fn
          ^first when not listed? -> [name]
          pack -> if pack in gone, do: [], else: [pack]
        end)

      {:write, %{state | packs: packs}, length(packs)}
    else
      {:stop, :superseded}
    end
  end

  # The next fetch then finds the merged pack in the cache.
  defp cache(snapshot, merged) do
    if snapshot.cache do
      key = Repository.pack_key(snapshot.repo, merged.name)

      with {:error, reason} <-
             PackCache.insert(snapshot.cache, key, merged.name, merged.pack, merged.idx),
           do: Logger.warning("git_server: pack cache: #{reason}")

      PackCache.evict(snapshot.cache)
    end

    :ok
  end
end
