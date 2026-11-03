defmodule GitServer.Repository do
  @moduledoc """
  A repository in the store: its `state` object and its packs, laid out as

      <name>.git/state
      <name>.git/packs/<checksum>.pack
      <name>.git/packs/<checksum>.idx

  `read_state/2` reads the state alone. `snapshot/3` also downloads every listed
  pack and idx into a fresh local directory, for reading objects; `release/1`
  deletes it, and `with_snapshot/4` does both around a function. `put_state/4` is
  the conditional state write, and `update/3` the loop every writer of a state goes
  through: compute the new state from a snapshot, write it conditionally, and on a
  lost race refresh and compute again. All of it uses only the store's generic
  calls.
  """

  alias GitServer.{RepoName, State, Store}

  defmodule Snapshot do
    @moduledoc """
    A repository state with its packs downloaded: `packs` holds a
    `{pack_path, idx_path}` pair for each pack the state lists, in the state's order.
    `etag` is the state's ETag, or `:absent` for an empty repository with no state
    object.
    """
    @enforce_keys [:store, :repo, :dir, :state, :etag, :packs]
    defstruct @enforce_keys
  end

  @doc "The store key of a repository's state."
  def state_key(repo), do: RepoName.key_prefix(repo) <> "state"

  @doc "The store key of a pack, by its checksum in hex."
  def pack_key(repo, name), do: RepoName.key_prefix(repo) <> "packs/#{name}.pack"

  @doc "The store key of a pack's idx, by the pack's checksum in hex."
  def idx_key(repo, name), do: RepoName.key_prefix(repo) <> "packs/#{name}.idx"

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
  Reads the state and downloads every pack and idx it lists into a new directory
  under `temp_dir`: `{:ok, snapshot}` or `{:error, reason}`. The directory is gone
  again on error; on success the caller deletes it with `release/1`.
  """
  def snapshot(store, repo, temp_dir) do
    with {:ok, dir} <- private_dir(temp_dir) do
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
  def update(%Snapshot{} = snapshot, deadline, fun), do: update(snapshot, deadline, fun, nil, 0)

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
  def with_snapshot(store, repo, temp_dir, fun) do
    with {:ok, snapshot} <- snapshot(store, repo, temp_dir) do
      try do
        fun.(snapshot)
      after
        release(snapshot)
      end
    end
  end

  defp download(snapshot, state, etag) do
    result =
      Enum.reduce_while(state.packs, {:ok, []}, fn name, {:ok, packs} ->
        case fetch_pack(snapshot, name) do
          {:ok, paths} -> {:cont, {:ok, [paths | packs]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, packs} <- result do
      {:ok, %{snapshot | state: state, etag: etag, packs: Enum.reverse(packs)}}
    end
  end

  # A pack already in the directory, from before a refresh, is not downloaded again.
  defp fetch_pack(snapshot, name) do
    pack_path = Path.join(snapshot.dir, "#{name}.pack")
    idx_path = Path.join(snapshot.dir, "#{name}.idx")

    if File.exists?(pack_path) and File.exists?(idx_path) do
      {:ok, {pack_path, idx_path}}
    else
      File.rm(pack_path)
      File.rm(idx_path)

      with {:ok, _} <- Store.get_file(snapshot.store, idx_key(snapshot.repo, name), idx_path),
           {:ok, _} <- Store.get_file(snapshot.store, pack_key(snapshot.repo, name), pack_path) do
        {:ok, {pack_path, idx_path}}
      else
        {:error, :not_found} -> {:error, "repository #{snapshot.repo}: pack #{name} is missing"}
        {:error, reason} -> {:error, reason}
      end
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
