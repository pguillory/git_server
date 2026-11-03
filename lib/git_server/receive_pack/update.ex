defmodule GitServer.ReceivePack.Update do
  @moduledoc false
  # The push itself, once `GitServer.ReceivePack` has read its commands and streamed
  # its pack to a file (steps 2 to 5 of that module's doc): index the pack, check it
  # and the commands against the repository, run `before_update`, store the pack and
  # publish the new state through `GitServer.Repository.update/3`.
  #
  # A command is `%{old: hex, new: hex, ref: name, error: nil | reason}`. Results are
  # `{unpack_status, commands}` or `{unpack_status, commands, message}`, each
  # command's error set when it was rejected, and `message` text for the client
  # from `before_update`.

  require Logger
  alias GitServer.Config
  alias GitServer.ObjectDB
  alias GitServer.ObjectId
  alias GitServer.Repository
  alias GitServer.State
  alias GitServer.Pack.Indexer

  @zero_id String.duplicate("0", 40)

  @doc """
  Runs a push's commands, with its pack at `pack_path` (nil when every command is a
  delete): index the pack, then check and publish.
  """
  def run(conn, config, repo, commands, options, nil) do
    update(conn, config, repo, commands, options, nil)
  end

  def run(conn, config, repo, commands, options, pack_path) do
    case Indexer.index(pack_path, Config.push_limits(config)) do
      {:ok, pack} -> update(conn, config, repo, commands, options, {pack_path, pack})
      {:error, reason} -> unpack_failed(commands, name_limit(reason, config))
    end
  end

  # The indexer's reasons for a push over a limit, with the limit.
  defp name_limit("pack too large", config) do
    "pack too large (limit #{Config.format_bytes(config.max_pack_bytes)})"
  end

  defp name_limit("object too large", config) do
    "object too large (limit #{Config.format_bytes(config.max_object_bytes)})"
  end

  defp name_limit("too many objects", config) do
    "too many objects in pack (limit #{config.max_objects})"
  end

  defp name_limit("delta chain too deep", config) do
    "delta chain too deep (limit #{config.max_delta_depth})"
  end

  defp name_limit(reason, _config) do
    reason
  end

  @doc """
  Calls the host's `after_update` function, if any, with the updates a push's result
  says landed: those reported `ok`, which only a successful state write produces. It
  runs in a process of its own, its result is ignored, and a failure or timeout is
  logged without the failure's message or values, as for `before_update`.
  """
  def after_update(%{after_update: nil}, _repo, _conn, _result) do
    :ok
  end

  def after_update(config, repo, conn, {unpack, commands}) do
    after_update(config, repo, conn, {unpack, commands, nil})
  end

  def after_update(config, repo, conn, {unpack, commands, _message}) do
    landed = Enum.filter(commands, &(&1.error == nil))

    if unpack == :ok and landed != [] do
      push = %{
        repo: repo,
        conn: conn,
        updates: Enum.map(landed, &%{ref: &1.ref, old: present(&1.old), new: present(&1.new)}),
      }

      call = fn ->
        try do
          config.after_update.(push)
          :ok
        catch
          # The host's function, outside this library: a failure is logged by kind
          # only, since the push may carry content and the conn credentials.
          kind, reason -> {:failed, GitServer.Failure.describe(kind, reason, __STACKTRACE__)}
        end
      end

      case GitServer.Worker.run(call, config.after_update_timeout_ms) do
        {:ok, :ok} -> :ok
        {:ok, {:failed, what}} -> after_update_failed(what)
        :exited -> after_update_failed("exited")
        :timeout -> after_update_failed("timed out after #{config.after_update_timeout_ms} ms")
      end
    end

    :ok
  end

  defp after_update_failed(what) do
    Logger.error("git_server: the after_update function #{what}")
  end

  @doc "Sets a command's error, unless it already has one."
  def reject(%{error: nil} = command, reason) do
    %{command | error: reason}
  end

  def reject(command, _reason) do
    command
  end

  @doc "Whether a command deletes its ref."
  def delete?(command) do
    command.new == @zero_id
  end

  @doc "Every command rejected for an unpack failure."
  def unpack_failed(commands, reason) do
    {{:error, reason}, Enum.map(commands, &reject(&1, "unpacker error"))}
  end

  @doc "Every command rejected for a storage failure, which is logged."
  def storage_failed(commands, reason) do
    Logger.error("git_server: store error during push: #{inspect(reason)}")
    Enum.map(commands, &reject(&1, "storage failed, try again later"))
  end

  # Steps 3 to 5, through `Repository.update/3`, so a lost race refreshes the
  # snapshot and checks again.
  defp update(conn, config, repo, commands, options, pack) do
    options = Map.put(options, :conn, conn)

    if Enum.all?(commands, & &1.error) do
      {:ok, commands}
    else
      case Repository.snapshot(
             config.store,
             repo,
             config.temp_dir,
             Config.snapshot_options(config)
           ) do
        {:ok, snapshot} ->
          try do
            deadline = System.monotonic_time(:millisecond) + config.push_deadline_ms
            attempt = &attempt(config, &1, commands, options, pack, &2)

            case Repository.update(snapshot, deadline, attempt) do
              {:ok, {checked, _name}} ->
                {:ok, checked}

              {:stop, result} ->
                result

              {:error, :deadline, {checked, _name}} ->
                {:ok,
                 Enum.map(checked, &reject(&1, "failed to update ref, too many pushes at once"))}

              {:error, reason, {checked, _name}} ->
                {:ok, storage_failed(checked, reason)}
            end
          after
            Repository.release(snapshot)
          end

        {:error, reason} ->
          {:ok, storage_failed(commands, reason)}
      end
    end
  end

  # One try against a snapshot: check, store the pack the first time, and return the
  # state to write, with `{checked, pack_name}`, which comes back as `last` after a
  # lost race. The object database is closed before the write, so retries never hold
  # more than one.
  defp attempt(config, snapshot, commands, options, pack, last) do
    checked =
      with_db(snapshot, config, fn db ->
        with :ok <- if(last == nil, do: check_links(pack, db), else: :ok) do
          {:ok, check_commands(commands, snapshot.state, pack, db, options)}
        end
      end)

    stored = if last, do: {:stored, elem(last, 1)}, else: :unstored

    # The host's check runs on every attempt, so the state written is always one it
    # approved: the write is conditional on exactly this snapshot's state.
    with {:ok, checked} <- checked,
         passing when passing != [] <- Enum.reject(checked, & &1.error),
         :ok <- before_update(config, snapshot, pack, options.conn, passing),
         {:ok, name} <- store_pack(config, snapshot, pack, stored) do
      {:write, apply_commands(snapshot.state, passing, name), {checked, name}}
    else
      [] ->
        {:stop, {:ok, elem(checked, 1)}}

      {:declined, reason, message} ->
        {:stop, {:ok, Enum.map(elem(checked, 1), &reject(&1, reason)), message}}

      {:error, :links, reason} ->
        {:stop, unpack_failed(commands, reason)}

      {:error, :storage, reason} ->
        {:stop, {:ok, storage_failed(commands, reason)}}

      {:error, reason} ->
        {:stop, {:ok, storage_failed(elem(checked, 1), reason)}}
    end
  end

  # The host's `before_update` function, on the updates that passed. It runs in its
  # own process, with its own object database, so a timeout can kill it. Returns :ok,
  # {:declined, reason, message}, or {:error, :storage, reason}.
  defp before_update(%{before_update: nil}, _snapshot, _pack, _conn, _passing) do
    :ok
  end

  defp before_update(config, snapshot, pack, conn, passing) do
    with {:ok, pushed} <- pushed_pack(pack) do
      fields = %{
        repo: snapshot.repo,
        conn: conn,
        refs: snapshot.state.refs,
        updates: Enum.map(passing, &%{ref: &1.ref, old: present(&1.old), new: present(&1.new)}),
      }

      packs = snapshot.packs ++ pushed

      case GitServer.Worker.run(
             fn -> call_before_update(config, packs, fields) end,
             config.before_update_timeout_ms
           ) do
        {:ok, :ok} -> :ok
        {:ok, {:reject, message}} -> {:declined, "declined", message}
        {:ok, {:storage, reason}} -> {:error, :storage, reason}
        {:ok, {:failed, what}} -> check_failed(what)
        :exited -> check_failed("exited")
        :timeout -> check_failed("timed out after #{config.before_update_timeout_ms} ms")
      end
    end
  end

  defp present(@zero_id) do
    nil
  end

  defp present(id) do
    id
  end

  # The pushed pack, with its idx beside it, for an object database.
  defp pushed_pack(nil) do
    {:ok, []}
  end

  defp pushed_pack({_path, %{objects: objects}}) when objects == %{} do
    {:ok, []}
  end

  defp pushed_pack({path, pack}) do
    idx_path = Path.rootname(path) <> ".idx"

    if File.exists?(idx_path) do
      {:ok, [{path, idx_path}]}
    else
      case File.write(idx_path, pack.idx) do
        :ok -> {:ok, [{path, idx_path}]}
        {:error, posix} -> {:error, :storage, "cannot write the pack index: #{posix}"}
      end
    end
  end

  # In the worker. Only the kind of a failure is reported, never an exception's
  # message or a returned value, which may quote pushed content.
  defp call_before_update(config, packs, fields) do
    case ObjectDB.open(packs, Config.read_options(config, fields.repo)) do
      {:ok, db} ->
        try do
          case config.before_update.(struct!(GitServer.Push, Map.put(fields, :db, db))) do
            :ok -> :ok
            {:reject, message} when is_binary(message) -> {:reject, message}
            _other -> {:failed, "returned something other than :ok or {:reject, message}"}
          end
        catch
          # The host's function, outside this library: a failure refuses the push.
          kind, reason -> {:failed, GitServer.Failure.describe(kind, reason, __STACKTRACE__)}
        after
          ObjectDB.close(db)
        end

      {:error, reason} ->
        {:storage, reason}
    end
  end

  defp check_failed(what) do
    Logger.error("git_server: the before_update function #{what}")
    {:declined, "push check failed", "The server could not check this push.\n"}
  end

  # The repository's objects, open in this process for the length of `fun`.
  defp with_db(snapshot, config, fun) do
    case ObjectDB.open(snapshot.packs, Config.read_options(config, snapshot.repo)) do
      {:ok, db} ->
        try do
          fun.(db)
        after
          ObjectDB.close(db)
        end

      {:error, reason} ->
        {:error, :storage, reason}
    end
  end

  # Invariant: every object in a listed pack has its referents in the listed packs.
  # Packs are only ever added, so this holds for any later state too.
  defp check_links(nil, _db) do
    :ok
  end

  # Each id outside the pack is looked up once, however many objects point to it.
  defp check_links({_path, pack}, db) do
    pack.objects
    |> Enum.reduce_while(%{}, fn {id, {_type, links}}, seen ->
      case link_errors(links, pack.objects, db, seen) do
        {:ok, seen} -> {:cont, seen}
        {:error, reason} -> {:halt, {:error, :links, "#{reason} (from #{ObjectId.to_hex(id)})"}}
      end
    end)
    |> case do
      {:error, :links, reason} -> {:error, :links, reason}
      _seen -> :ok
    end
  end

  defp link_errors([], _objects, _db, seen) do
    {:ok, seen}
  end

  defp link_errors([{type, id} | links], objects, db, seen) do
    {found, seen} =
      case seen do
        %{^id => found} ->
          {found, seen}

        _ ->
          found = object_type(id, objects, db)
          {found, if(is_map_key(objects, id), do: seen, else: Map.put(seen, id, found))}
      end

    case found do
      {:ok, ^type} -> link_errors(links, objects, db, seen)
      {:ok, other} -> {:error, "#{ObjectId.to_hex(id)} is a #{other}, not a #{type}"}
      :error -> {:error, "missing #{type} #{ObjectId.to_hex(id)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp object_type(id, objects, db) do
    case objects do
      %{^id => {type, _links}} ->
        {:ok, type}

      _ ->
        case ObjectDB.lookup(db, id) do
          {:ok, type, _size} -> {:ok, type}
          other -> other
        end
    end
  end

  # Each command against a state. Errors found before (names, duplicates) stay.
  defp check_commands(commands, state, pack, db, options) do
    objects = if pack, do: elem(pack, 1).objects, else: %{}

    checked =
      commands
      |> Enum.map(fn command ->
        case command_error(command, state, objects, db) do
          nil -> command
          reason -> reject(command, reason)
        end
      end)
      |> reject_conflicts(state)

    if options.atomic and Enum.any?(checked, & &1.error),
      do: Enum.map(checked, &reject(&1, "atomic push failure")),
      else: checked
  end

  # A new ref can't sit where another ref is a directory of it or it of another
  # (refs/heads/a beside refs/heads/a/b), which git's clients couldn't store.
  defp reject_conflicts(commands, state) do
    passing = Enum.reject(commands, & &1.error)

    names =
      Enum.reduce(passing, MapSet.new(Map.keys(state.refs)), fn command, names ->
        if delete?(command),
          do: MapSet.delete(names, command.ref),
          else: MapSet.put(names, command.ref)
      end)

    Enum.map(commands, fn command ->
      if command.error == nil and not delete?(command) and
           not Map.has_key?(state.refs, command.ref) and conflict?(command.ref, names),
         do: reject(command, "ref name conflicts with an existing ref"),
         else: command
    end)
  end

  defp conflict?(ref, names) do
    parts = String.split(ref, "/")

    parent? =
      Enum.any?(1..(length(parts) - 1)//1, fn n ->
        MapSet.member?(names, parts |> Enum.take(n) |> Enum.join("/"))
      end)

    parent? or Enum.any?(names, &String.starts_with?(&1, ref <> "/"))
  end

  defp command_error(%{error: error}, _state, _objects, _db) when error != nil do
    nil
  end

  defp command_error(command, state, objects, db) do
    current = Map.get(state.refs, command.ref, @zero_id)

    cond do
      command.old != current ->
        "fetch first"

      delete?(command) ->
        nil

      true ->
        {:ok, id} = ObjectId.from_hex(command.new)

        case object_type(id, objects, db) do
          {:ok, :commit} -> nil
          {:ok, _type} -> if branch?(command.ref), do: "not a commit", else: nil
          :error -> "missing object"
          {:error, reason} -> reason
        end
    end
  end

  defp branch?(ref) do
    String.starts_with?(ref, "refs/heads/")
  end

  # Step 5a: the pack and idx, before the first state write. A pack with no objects
  # is neither stored nor listed, and one the state already lists (a client retrying)
  # isn't stored again.
  defp store_pack(_config, _snapshot, _pack, {:stored, name}) do
    {:ok, name}
  end

  defp store_pack(_config, _snapshot, nil, :unstored) do
    {:ok, nil}
  end

  defp store_pack(_config, _snapshot, {_path, %{objects: objects}}, :unstored)
       when objects == %{} do
    {:ok, nil}
  end

  defp store_pack(config, snapshot, {path, pack}, :unstored) do
    name = ObjectId.to_hex(pack.checksum)

    if name in snapshot.state.packs do
      {:ok, name}
    else
      with :ok <- Repository.put_pack(config.store, snapshot.repo, name, path, pack.idx),
           do: {:ok, name}
    end
  end

  # The state after `commands`, which all passed against `state`.
  defp apply_commands(%State{} = state, commands, pack_name) do
    refs =
      Enum.reduce(commands, state.refs, fn command, refs ->
        if delete?(command),
          do: Map.delete(refs, command.ref),
          else: Map.put(refs, command.ref, command.new)
      end)

    created =
      for command <- commands,
          not delete?(command),
          branch?(command.ref),
          not Map.has_key?(state.refs, command.ref),
          do: command.ref

    head =
      cond do
        Map.has_key?(refs, state.head) or created == [] -> state.head
        Map.has_key?(refs, "refs/heads/main") -> "refs/heads/main"
        Map.has_key?(refs, "refs/heads/master") -> "refs/heads/master"
        true -> Enum.min(created)
      end

    packs =
      if pack_name == nil or pack_name in state.packs,
        do: state.packs,
        else: state.packs ++ [pack_name]

    %State{state | head: head, refs: refs, packs: packs}
  end
end
