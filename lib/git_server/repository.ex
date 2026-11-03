defmodule GitServer.Repository do
  @moduledoc """
  A repository in the store: its `state` object and its packs, laid out as

      <name>.git/state
      <name>.git/packs/<checksum>.pack
      <name>.git/packs/<checksum>.idx

  `read_state/2` reads the state alone. `snapshot/4` also downloads every listed
  pack and idx into a fresh local directory, for reading objects; `release/1`
  deletes it, and `with_snapshot/5` does both around a function. `put_state/4` is
  the conditional state write, and `update/3` the loop every writer of a state goes
  through: compute the new state from a snapshot, write it conditionally, and on a
  lost race refresh and compute again. All of it uses only the store's generic
  calls.
  """

  require Logger

  alias GitServer.Failure
  alias GitServer.PackCache
  alias GitServer.RepoName
  alias GitServer.State
  alias GitServer.Store

  defmodule Snapshot do
    @moduledoc """
    A repository state with its packs downloaded: `packs` holds a
    `{pack_path, idx_path}` pair for each pack the state lists, in the state's order,
    or with `only` set, for each of those packs the state lists.
    `etag` is the state's ETag, or `:absent` for an empty repository with no state
    object.
    """
    @enforce_keys [:store, :repo, :dir, :state, :etag, :packs]
    defstruct [:concurrency, :cache, :only | @enforce_keys]
  end

  @doc "The store key of a repository's state."
  def state_key(repo) do
    RepoName.key_prefix(repo) <> "state"
  end

  @doc "The store key of a pack, by its checksum in hex."
  def pack_key(repo, name) do
    RepoName.key_prefix(repo) <> "packs/#{name}.pack"
  end

  @doc "The store key of a pack's idx, by the pack's checksum in hex."
  def idx_key(repo, name) do
    RepoName.key_prefix(repo) <> "packs/#{name}.idx"
  end

  @doc """
  Reads a repository's state: `{:ok, state, etag}`, or `{:ok, State.new(), :absent}`
  for a repository with no state object, or `{:error, reason}`.
  """
  def read_state(store, repo) do
    case Store.get(store, state_key(repo)) do
      {:ok, text, etag} ->
        case State.decode(text) do
          {:ok, state} -> {:ok, state, etag}
          {:error, reason} -> {:error, "repository #{repo}: #{reason}"}
        end

      {:error, :not_found} ->
        {:ok, State.new(), :absent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Writes a repository's state only if it is still at `etag` (or still absent, for
  `:absent`): `{:ok, new_etag}`, `{:error, :precondition_failed}` when another
  write got there first, or `{:error, reason}`.
  """
  def put_state(store, repo, %State{} = state, etag) do
    condition = if etag == :absent, do: :absent, else: {:etag, etag}
    Store.put(store, state_key(repo), State.encode(state), condition)
  end

  @doc """
  Stores a pack, from the file at `pack_path`, and its idx under the pack's name
  (its checksum in hex), both at once: `:ok` or `{:error, reason}`. Unconditional:
  the name is the content's checksum, so writing it again is harmless. Only a state
  write that lists the pack must come after both.
  """
  def put_pack(store, repo, name, pack_path, idx) do
    idx_task =
      Task.async(fn ->
        Failure.catching("the store upload", fn ->
          Store.put(store, idx_key(repo, name), idx, :none)
        end)
      end)

    stored = Store.put_file(store, pack_key(repo, name), pack_path, :none)
    idx_stored = Task.await(idx_task, :infinity)

    with {:ok, _} <- stored,
         {:ok, _} <- idx_stored do
      :ok
    end
  end

  @doc """
  Reads the state and downloads every pack and idx it lists into a new directory
  under `temp_dir`: `{:ok, snapshot}` or `{:error, reason}`. The directory is gone
  again on error; on success the caller deletes it with `release/1`.

  Files are downloaded `:concurrency` at a time (default 8), here and in
  `refresh/1`. The first failed download stops the others, and a file stopped part
  way never stands under its final name. With `cache: {dir, max_bytes}`, packs come
  from that `GitServer.PackCache` when it has them, and downloaded ones go into it;
  a cache directory that can't be created is logged and the snapshot goes on
  without it. With `only:` a list of pack names, only those of them the state lists
  are downloaded, here and in `refresh/1`, for a caller that reads no others.
  """
  def snapshot(store, repo, temp_dir, opts \\ []) do
    with {:ok, cache} <- open_cache(opts[:cache], store),
         {:ok, dir} <- private_dir(temp_dir) do
      result =
        try do
          with {:ok, state, etag} <- read_state(store, repo) do
            snapshot = %Snapshot{
              store: store,
              repo: repo,
              dir: dir,
              state: state,
              etag: etag,
              packs: [],
              concurrency: Keyword.get(opts, :concurrency, 8),
              cache: cache,
              only: opts[:only] && MapSet.new(opts[:only]),
            }

            download(snapshot, state, etag)
          end
        catch
          kind, reason ->
            File.rm_rf(dir)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      with {:error, _} <- result, do: File.rm_rf(dir)
      result
    end
  end

  # A cache that can't be used doesn't fail the request, which goes on without it.
  defp open_cache(nil, _store) do
    {:ok, nil}
  end

  defp open_cache({dir, max_bytes}, store) do
    case PackCache.open(dir, max_bytes, store) do
      {:ok, cache} ->
        {:ok, cache}

      {:error, reason} ->
        Logger.warning("git_server: #{reason}")
        {:ok, nil}
    end
  end

  @doc """
  Re-reads the state into an existing snapshot, downloading only packs it did not
  have yet: `{:ok, snapshot}` or `{:error, reason}`. Used when a conditional state
  write lost a race. The directory stays the caller's to release either way.
  """
  def refresh(%Snapshot{} = snapshot) do
    with {:ok, state, etag} <- read_state(snapshot.store, snapshot.repo) do
      download(snapshot, state, etag)
    end
  end

  @doc """
  Changes a repository's state with the conditional write, retried while other
  writers win, until `deadline` (in `System.monotonic_time(:millisecond)`).

  `fun.(snapshot, last)` computes the change against `snapshot`, where `last` is
  `nil` on the first call and, after a lost race, the result its previous call
  returned. It returns `{:write, new_state, result}` to write `new_state`
  conditionally on exactly `snapshot`'s state, or `{:stop, result}` to write
  nothing. After a lost race the loop waits a jittered, growing backoff, refreshes
  the snapshot (`refresh/1`) and calls `fun` again.

  Returns `{:ok, result}` once a write succeeded, `{:stop, result}`, or
  `{:error, reason, result}` with `result` from the last call of `fun`: `reason` is
  `:deadline` when a race was lost at or past the deadline, or the store's reason
  when a write or refresh failed.
  """
  def update(%Snapshot{} = snapshot, deadline, fun) do
    update(snapshot, deadline, fun, nil, 0)
  end

  defp update(snapshot, deadline, fun, last, n) do
    case fun.(snapshot, last) do
      {:write, %State{} = state, result} ->
        case put_state(snapshot.store, snapshot.repo, state, snapshot.etag) do
          {:ok, _etag} ->
            {:ok, result}

          {:error, :precondition_failed} ->
            if System.monotonic_time(:millisecond) >= deadline do
              {:error, :deadline, result}
            else
              Process.sleep(:rand.uniform(min(1000, 25 * 2 ** min(n, 6))))

              case refresh(snapshot) do
                {:ok, snapshot} -> update(snapshot, deadline, fun, result, n + 1)
                {:error, reason} -> {:error, reason, result}
              end
            end

          {:error, reason} ->
            {:error, reason, result}
        end

      {:stop, result} ->
        {:stop, result}
    end
  end

  @doc "Deletes a snapshot's local files."
  def release(%Snapshot{dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  @doc """
  Runs `fun` on a snapshot and deletes its files afterwards, even if `fun` raises:
  `fun`'s result, or `{:error, reason}` if the snapshot could not be made.
  """
  def with_snapshot(store, repo, temp_dir, opts \\ [], fun) do
    with {:ok, snapshot} <- snapshot(store, repo, temp_dir, opts) do
      try do
        fun.(snapshot)
      after
        release(snapshot)
      end
    end
  end

  # Only files not already in the directory, from before a refresh, or in the cache
  # are downloaded.
  defp download(snapshot, state, etag) do
    names =
      if snapshot.only,
        do: Enum.filter(state.packs, &MapSet.member?(snapshot.only, &1)),
        else: state.packs

    paths = Map.new(names, &{&1, pack_paths(snapshot, &1)})

    if snapshot.cache do
      Enum.each(names, fn name ->
        {pack_path, idx_path} = paths[name]

        if not File.exists?(pack_path) and not File.exists?(idx_path),
          do: PackCache.take(snapshot.cache, pack_key(snapshot.repo, name), pack_path, idx_path)
      end)
    end

    files =
      for name <- names,
          {pack_path, idx_path} = paths[name],
          {key, path} <- [
            {idx_key(snapshot.repo, name), idx_path},
            {pack_key(snapshot.repo, name), pack_path},
          ],
          not File.exists?(path),
          do: {name, key, path}

    # Halting the stream at the first failure stops the downloads still running. A
    # task catches its own failures, so none exits this process.
    %Snapshot{store: store, repo: repo} = snapshot

    failure =
      files
      |> Task.async_stream(
        fn file ->
          Failure.catching("the store download", fn -> fetch_file(store, repo, file) end)
        end,
        max_concurrency: snapshot.concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.find_value(fn
        {:ok, :ok} -> nil
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, _reason} -> {:error, "the store download exited"}
      end)

    downloaded = files |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    with nil <- failure,
         :ok <- cache_downloads(snapshot, downloaded, paths) do
      {:ok, %{snapshot | state: state, etag: etag, packs: Enum.map(names, &paths[&1])}}
    end
  end

  # A pack that fails the cache's checks is a storage error, and its files go, so a
  # later refresh doesn't take them as present.
  defp cache_downloads(%Snapshot{cache: nil}, _names, _paths) do
    :ok
  end

  defp cache_downloads(_snapshot, [], _paths) do
    :ok
  end

  defp cache_downloads(snapshot, names, paths) do
    result =
      Enum.find_value(names, :ok, fn name ->
        {pack_path, idx_path} = paths[name]
        key = pack_key(snapshot.repo, name)

        case PackCache.insert(snapshot.cache, key, name, pack_path, idx_path) do
          :ok ->
            nil

          {:error, reason} ->
            File.rm(pack_path)
            File.rm(idx_path)
            {:error, "repository #{snapshot.repo}: pack #{name}: #{reason}"}
        end
      end)

    PackCache.evict(snapshot.cache)
    result
  end

  defp pack_paths(snapshot, name) do
    {Path.join(snapshot.dir, "#{name}.pack"), Path.join(snapshot.dir, "#{name}.idx")}
  end

  # Downloaded under a temporary name and renamed into place whole.
  defp fetch_file(store, repo, {name, key, path}) do
    part = path <> ".part"
    File.rm(part)

    case Store.get_file(store, key, part) do
      {:ok, _etag} ->
        with {:error, posix} <- File.rename(part, path),
             do: {:error, "cannot rename a downloaded file: #{:file.format_error(posix)}"}

      {:error, :not_found} ->
        {:error, "repository #{repo}: pack #{name} is missing"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates an exclusive directory under `temp_dir`, with a random name unrelated to
  any repository's and readable only by this user: `{:ok, dir}` or
  `{:error, reason}`. The caller removes it.
  """
  def private_dir(temp_dir) do
    dir =
      Path.join(
        temp_dir,
        "git_server-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    # Private to this user: the packs may hold private repositories.
    # Only a directory this call created is ever removed.
    result =
      case File.mkdir(dir) do
        :ok ->
          with {:error, posix} <- File.chmod(dir, 0o700) do
            File.rm_rf(dir)
            {:error, posix}
          end

        {:error, posix} ->
          {:error, posix}
      end

    case result do
      :ok ->
        {:ok, dir}

      {:error, posix} ->
        {:error,
         "cannot create a temporary directory in #{temp_dir}: #{:file.format_error(posix)}"}
    end
  end
end
