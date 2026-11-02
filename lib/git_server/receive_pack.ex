defmodule GitServer.ReceivePack do
  @moduledoc """
  Push, over protocol v0's `git-receive-pack` (gitprotocol-pack): the ref
  advertisement and the push request.

  A push is a list of ref update commands (`<old> <new> <ref>`), the first carrying
  the client's capabilities, then a flush, then the pack whenever a command isn't a
  delete. It is handled in this order:

  1. The commands are read under the command cap. A body of only a flush is git's
     probe before a large push and gets an empty reply.
  2. The pack is streamed to a temporary file and indexed: every delta is resolved
     with its base in the pack itself (no thin packs), every object hashed and
     parsed.
  3. The repository's state is read and its packs downloaded. Every object in the
     new pack must have its referents, of the right types, in the new pack or the
     repository's packs. Each command is checked against the state: `old` equal to
     the ref's current value (the zero id meaning absent), a `new` that exists, a
     commit for a branch, and no new ref beside a ref that is its directory or
     inside it. (Ref names, and duplicate commands for one ref, were checked when
     the commands were read.)
  4. The pack and its idx are stored, and then the new state is written only if the
     state is still the one checked. When another push got there first, the state
     is read again, the commands checked again, and the write retried, with jittered
     backoff, until `push_deadline_ms` has passed.
  5. The result goes back as report-status, on side-band 1 when the client asked
     for `side-band-64k`.

  Without `atomic`, commands that pass are applied and the others rejected. With it,
  one rejection rejects them all. Nothing is ever deleted here: a stored pack that no
  state lists is harmless garbage.

  If a push leaves HEAD's target missing and creates branches, HEAD moves to
  `refs/heads/main` if it exists, else `refs/heads/master`, else the first branch
  created, by name.
  """

  require Logger
  alias GitServer.{Body, ObjectDB, ObjectId, PktLine, RefName, Repository, State, Store}
  alias GitServer.Pack.Indexer

  @service "git-receive-pack"
  @zero_id String.duplicate("0", 40)
  @capabilities "report-status delete-refs side-band-64k quiet atomic ofs-delta no-thin"

  @doc """
  The ref advertisement. The capabilities ride on the first ref line; an empty
  repository advertises them on a placeholder `capabilities^{}` with the zero id.
  """
  def advertise(conn, config, repo) do
    case Repository.read_state(config.store, repo) do
      {:ok, state, _etag} ->
        capabilities = "#{@capabilities} agent=#{GitServer.Plug.agent()} object-format=sha1"

        [{first_name, first_id} | rest] =
          case Enum.sort(state.refs) do
            [] -> [{"capabilities^{}", @zero_id}]
            refs -> refs
          end

        GitServer.Plug.advertise(conn, @service, [
          PktLine.encode("# service=git-receive-pack\n"),
          PktLine.flush(),
          PktLine.encode("#{first_id} #{first_name}\0#{capabilities}\n"),
          Enum.map(rest, fn {name, id} -> PktLine.encode("#{id} #{name}\n") end),
          PktLine.flush(),
        ])

      {:error, reason} ->
        GitServer.Plug.store_error(conn, reason)
    end
  end

  @doc "Handles a push request. Returns the sent conn."
  def push(conn, config, repo) do
    # The command section has its own cap, checked as it is read.
    case Body.reader(conn, config.max_command_bytes + config.max_pack_bytes) do
      {:ok, reader} -> read_commands(reader, config, repo, "", 0, [])
      {:error, reason, conn} -> GitServer.Plug.body_error(conn, reason)
    end
  end

  # Step 1: the command pkt-lines, up to their flush.
  defp read_commands(reader, config, repo, buffer, used, lines) do
    case PktLine.decode_one(buffer) do
      {:ok, :flush, rest} ->
        commands(reader, config, repo, Enum.reverse(lines), rest)

      {:ok, line, rest} when is_binary(line) ->
        used = used + byte_size(buffer) - byte_size(rest)

        if used > config.max_command_bytes,
          do: too_large(reader),
          else: read_commands(reader, config, repo, rest, used, [line | lines])

      {:ok, _special, _rest} ->
        malformed(reader, "malformed push commands")

      {:error, reason} ->
        malformed(reader, reason)

      :incomplete when used + byte_size(buffer) > config.max_command_bytes ->
        too_large(reader)

      :incomplete ->
        case Body.next(reader) do
          {:ok, chunk, reader} ->
            read_commands(reader, config, repo, buffer <> chunk, used, lines)

          {:done, conn} ->
            GitServer.Plug.text(conn, 400, "Truncated push request")

          {:error, reason, conn} ->
            GitServer.Plug.body_error(conn, reason)
        end
    end
  end

  defp too_large(reader) do
    conn = Body.close(reader)
    GitServer.Plug.body_error(conn, :too_large)
  end

  defp malformed(reader, reason) do
    conn = Body.close(reader)
    GitServer.Plug.text(conn, 400, "Malformed push request: #{reason}")
  end

  defp commands(reader, _config, _repo, [], rest) do
    probe(reader, rest)
  end

  defp commands(reader, config, repo, [first | others], rest) do
    {first, capabilities} =
      case :binary.split(first, <<0>>) do
        [command, capabilities] -> {command, String.split(PktLine.chomp(capabilities), " ")}
        [command] -> {command, []}
      end

    with {:ok, commands} <- parse_commands([first | others]),
         :ok <- check_capabilities(capabilities) do
      options = %{
        side_band: "side-band-64k" in capabilities,
        report: "report-status" in capabilities,
        atomic: "atomic" in capabilities,
      }

      commands = commands |> check_names() |> check_duplicates()

      if Enum.all?(commands, &delete?/1) do
        conn = Body.close(reader)
        reply(conn, options, update(config, repo, commands, options, nil))
      else
        receive_pack(reader, config, repo, commands, options, rest)
      end
    else
      {:error, reason} -> malformed(reader, reason)
    end
  end

  # The probe: a body of only a flush. It changes nothing.
  defp probe(reader, "") do
    case Body.next(reader) do
      {:done, conn} -> GitServer.Plug.result(conn, @service, [])
      {:ok, chunk, reader} -> probe(reader, chunk)
      {:error, reason, conn} -> GitServer.Plug.body_error(conn, reason)
    end
  end

  defp probe(reader, _data) do
    malformed(reader, "data after an empty command list")
  end

  defp parse_commands(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case PktLine.chomp(line) do
        <<old::binary-size(40), " ", new::binary-size(40), " ", ref::binary>> ->
          if hex_id?(old) and hex_id?(new) and ref != "" do
            {:cont, {:ok, [%{old: old, new: new, ref: ref, error: nil} | acc]}}
          else
            {:halt, {:error, "malformed command"}}
          end

        _ ->
          {:halt, {:error, "malformed command"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp hex_id?(text), do: text =~ ~r/\A[0-9a-f]{40}\z/

  # Unknown capabilities are ignored, as git's receive-pack does, but the object
  # format must be ours.
  defp check_capabilities(capabilities) do
    case Enum.find(capabilities, &String.starts_with?(&1, "object-format=")) do
      nil -> :ok
      "object-format=sha1" -> :ok
      "object-format=" <> format -> {:error, "unsupported object-format #{format}"}
    end
  end

  defp check_names(commands) do
    Enum.map(commands, fn command ->
      if RefName.valid?(command.ref), do: command, else: reject(command, "invalid ref name")
    end)
  end

  defp check_duplicates(commands) do
    counts = Enum.frequencies_by(commands, & &1.ref)

    Enum.map(commands, fn command ->
      if counts[command.ref] > 1, do: reject(command, "duplicate ref command"), else: command
    end)
  end

  defp reject(%{error: nil} = command, reason), do: %{command | error: reason}
  defp reject(command, _reason), do: command

  defp delete?(command), do: command.new == @zero_id

  # Step 2: the pack, streamed to a file and indexed.
  defp receive_pack(reader, config, repo, commands, options, rest) do
    # The pack may hold a private repository's objects.
    case Repository.private_dir(config.temp_dir) do
      {:ok, dir} ->
        try do
          receive_pack(reader, config, repo, commands, options, rest, Path.join(dir, "push.pack"))
        after
          File.rm_rf(dir)
        end

      {:error, reason} ->
        conn = Body.close(reader)
        reply(conn, options, {:ok, storage_failed(commands, reason)})
    end
  end

  defp receive_pack(reader, config, repo, commands, options, rest, path) do
    case Body.copy_to_file(reader, rest, path) do
      {:ok, conn} ->
        result =
          case Indexer.index(path,
                 max_pack_bytes: config.max_pack_bytes,
                 max_object_bytes: config.max_object_bytes
               ) do
            {:ok, pack} -> update(config, repo, commands, options, {path, pack})
            {:error, reason} -> unpack_failed(commands, reason)
          end

        reply(conn, options, result)

      {:error, reason, conn} ->
        reply(conn, options, unpack_failed(commands, read_error(reason)))
    end
  end

  defp read_error(:too_large), do: "pack too large"
  defp read_error(:bad_gzip), do: "malformed gzip body"
  defp read_error(_reason), do: "cannot read the pack"

  defp unpack_failed(commands, reason) do
    {{:error, reason}, Enum.map(commands, &reject(&1, "unpacker error"))}
  end

  # Steps 3 and 4. Returns {unpack_status, commands}, each command's error set when
  # it was rejected.
  defp update(config, repo, commands, options, pack) do
    if Enum.all?(commands, & &1.error) do
      {:ok, commands}
    else
      case Repository.snapshot(config.store, repo, config.temp_dir) do
        {:ok, snapshot} ->
          try do
            deadline = System.monotonic_time(:millisecond) + config.push_deadline_ms
            attempt(config, snapshot, commands, options, pack, :unstored, deadline, 0)
          after
            Repository.release(snapshot)
          end

        {:error, reason} ->
          {:ok, storage_failed(commands, reason)}
      end
    end
  end

  # One try against a snapshot: check, store the pack the first time, write the
  # state. A lost race refreshes the snapshot and tries again; the object database
  # is closed before then, so retries never hold more than one.
  defp attempt(config, snapshot, commands, options, pack, stored, deadline, n) do
    checked =
      with_db(snapshot, config, fn db ->
        with :ok <- if(n == 0, do: check_links(pack, db), else: :ok) do
          {:ok, check_commands(commands, snapshot.state, pack, db, options)}
        end
      end)

    # The point for a future `before_update` hook (validation of the updates before
    # anything is stored), which could reject commands and send messages on band 2.

    with {:ok, checked} <- checked,
         passing when passing != [] <- Enum.reject(checked, & &1.error),
         {:ok, name} <- store_pack(config, snapshot, pack, stored) do
      new_state = apply_commands(snapshot.state, passing, name)

      case Repository.put_state(config.store, snapshot.repo, new_state, snapshot.etag) do
        {:ok, _etag} ->
          {:ok, checked}

        {:error, :precondition_failed} ->
          if System.monotonic_time(:millisecond) >= deadline do
            {:ok, Enum.map(checked, &reject(&1, "failed to update ref"))}
          else
            Process.sleep(:rand.uniform(min(1000, 25 * 2 ** min(n, 6))))

            case Repository.refresh(snapshot) do
              {:ok, snapshot} ->
                attempt(
                  config,
                  snapshot,
                  commands,
                  options,
                  pack,
                  {:stored, name},
                  deadline,
                  n + 1
                )

              {:error, reason} ->
                {:ok, storage_failed(checked, reason)}
            end
          end

        {:error, reason} ->
          {:ok, storage_failed(checked, reason)}
      end
    else
      [] -> {:ok, elem(checked, 1)}
      {:error, :links, reason} -> unpack_failed(commands, reason)
      {:error, :storage, reason} -> {:ok, storage_failed(commands, reason)}
      {:error, reason} -> {:ok, storage_failed(elem(checked, 1), reason)}
    end
  end

  # The repository's objects, open in this process for the length of `fun`.
  defp with_db(snapshot, config, fun) do
    case ObjectDB.open(snapshot.packs, max_object_bytes: config.max_object_bytes) do
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
  defp check_links(nil, _db), do: :ok

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

  defp link_errors([], _objects, _db, seen), do: {:ok, seen}

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

  defp command_error(%{error: error}, _state, _objects, _db) when error != nil, do: nil

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

  defp branch?(ref), do: String.starts_with?(ref, "refs/heads/")

  # Step 4a: the pack and idx, before the first state write. A pack with no objects
  # is neither stored nor listed, and one the state already lists (a client retrying)
  # isn't stored again.
  defp store_pack(_config, _snapshot, _pack, {:stored, name}), do: {:ok, name}
  defp store_pack(_config, _snapshot, nil, :unstored), do: {:ok, nil}

  defp store_pack(_config, _snapshot, {_path, %{objects: objects}}, :unstored)
       when objects == %{},
       do: {:ok, nil}

  defp store_pack(config, snapshot, {path, pack}, :unstored) do
    name = ObjectId.to_hex(pack.checksum)

    if name in snapshot.state.packs do
      {:ok, name}
    else
      with {:ok, _} <-
             Store.put_file(config.store, Repository.pack_key(snapshot.repo, name), path, :none),
           {:ok, _} <-
             Store.put(config.store, Repository.idx_key(snapshot.repo, name), pack.idx, :none) do
        {:ok, name}
      end
    end
  end

  defp storage_failed(commands, reason) do
    Logger.error("git_server: store error during push: #{inspect(reason)}")
    Enum.map(commands, &reject(&1, "storage error"))
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

  # Step 5: report-status, inner pkt-lines ending in a flush.
  defp reply(conn, options, {unpack, commands}) do
    unpack_line =
      case unpack do
        :ok -> "unpack ok\n"
        {:error, reason} -> "unpack #{one_line(reason)}\n"
      end

    command_lines =
      Enum.map(commands, fn
        %{error: nil, ref: ref} -> "ok #{ref}\n"
        %{error: error, ref: ref} -> "ng #{ref} #{one_line(error)}\n"
      end)

    report = [Enum.map([unpack_line | command_lines], &PktLine.encode/1), PktLine.flush()]

    body =
      cond do
        not options.report -> []
        options.side_band -> [PktLine.sideband(1, report), PktLine.flush()]
        true -> report
      end

    GitServer.Plug.result(conn, @service, body)
  end

  # One report line's text, short enough for its pkt-line whatever it quotes.
  defp one_line(text) do
    text = String.replace(text, ~r/[\r\n]/, " ")
    if byte_size(text) > 1000, do: binary_part(text, 0, 1000), else: text
  end
end
