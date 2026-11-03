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
  4. The host's `:before_update` function, if any, is called with the updates that
     passed (see "Checking a push" below).
  5. The pack and its idx are stored, and then the new state is written only if the
     state is still the one checked. When another push got there first, the state
     is read again, the commands and `:before_update` checked again, and the write
     retried, with jittered backoff, until `push_deadline_ms` has passed.
  6. The result goes back as report-status, on side-band 1 when the client asked
     for `side-band-64k`, after any message from `:before_update` on side-band 2.

  Without `atomic`, commands that pass are applied and the others rejected. With it,
  one rejection rejects them all. Nothing is ever deleted here: a stored pack that no
  state lists is harmless garbage.

  If a push leaves HEAD's target missing and creates branches, HEAD moves to
  `refs/heads/main` if it exists, else `refs/heads/master`, else the first branch
  created, by name.

  ## Checking a push

  The `:before_update` option is a function of one `GitServer.Push`: the repository,
  the conn, its refs before the push, and the updates that will land if it approves.
  It can read files at any commit with `GitServer.Push.list_files/3` and
  `GitServer.Push.read_file/3`. It is called only when at least one update passed the
  server's own checks (the old value matches, the new object exists, a branch names a
  commit, no ref name conflict, and `atomic`). Those checks don't refuse a forced
  push; the function can.

  It returns `:ok` to approve, or `{:reject, message}` to refuse the whole push: every
  update it was shown fails with `declined`, and `message`, as given and of any length,
  goes to the client on side-band 2, which git prints as `remote:` lines. The message
  isn't changed or escaped, so quote pushed names in it with care. A ref the server
  already rejected keeps its own reason.

  It runs in a process of its own, killed if the request ends. If it raises, throws,
  exits, returns anything else or runs past `:before_update_timeout_ms`, the push is
  refused with `push check failed` and a fixed message, and the server logs the kind
  of failure, an exception's module and the stacktrace without arguments, never an
  exception's message or anything pushed.

  When the state write loses a race, the function is called again against the new
  state, and the write is conditional on exactly the state it was shown, so a push
  only ever lands on a state the latest call approved. So it may be called more than
  once for one push, and its approval doesn't mean the push landed. A rejection after
  a lost race may leave the pack stored but unlisted, harmless as any unlisted pack.
  A retry starts only before `push_deadline_ms`, so a slow function makes a push run
  that much longer.
  """

  alias GitServer.{HTTP, Body, PktLine, RefName, Repository}
  alias GitServer.ReceivePack.Update

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
        capabilities = "#{@capabilities} agent=#{HTTP.agent()} object-format=sha1"

        [{first_name, first_id} | rest] =
          case Enum.sort(state.refs) do
            [] -> [{"capabilities^{}", @zero_id}]
            refs -> refs
          end

        HTTP.advertise(conn, @service, [
          PktLine.encode("# service=git-receive-pack\n"),
          PktLine.flush(),
          PktLine.encode("#{first_id} #{first_name}\0#{capabilities}\n"),
          Enum.map(rest, fn {name, id} -> PktLine.encode("#{id} #{name}\n") end),
          PktLine.flush(),
        ])

      {:error, reason} ->
        HTTP.store_error(conn, reason)
    end
  end

  @doc "Handles a push request. Returns the sent conn."
  def push(conn, config, repo) do
    # The command section has its own cap, checked as it is read.
    case Body.reader(conn, config.max_command_bytes + config.max_pack_bytes) do
      {:ok, reader} -> read_commands(reader, config, repo, "", 0, [])
      {:error, reason, conn} -> HTTP.body_error(conn, reason)
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
            HTTP.text(conn, 400, "Truncated push request")

          {:error, reason, conn} ->
            HTTP.body_error(conn, reason)
        end
    end
  end

  defp too_large(reader) do
    conn = Body.close(reader)
    HTTP.body_error(conn, :too_large)
  end

  defp malformed(reader, reason) do
    conn = Body.close(reader)
    HTTP.text(conn, 400, "Malformed push request: #{reason}")
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

      if Enum.all?(commands, &Update.delete?/1) do
        conn = Body.close(reader)
        reply(conn, options, Update.run(conn, config, repo, commands, options, nil))
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
      {:done, conn} -> HTTP.result(conn, @service, [])
      {:ok, chunk, reader} -> probe(reader, chunk)
      {:error, reason, conn} -> HTTP.body_error(conn, reason)
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
      if RefName.valid?(command.ref),
        do: command,
        else: Update.reject(command, "invalid ref name")
    end)
  end

  defp check_duplicates(commands) do
    counts = Enum.frequencies_by(commands, & &1.ref)

    Enum.map(commands, fn command ->
      if counts[command.ref] > 1,
        do: Update.reject(command, "duplicate ref command"),
        else: command
    end)
  end

  # Step 2: the pack, streamed to a file for the update to index.
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
        reply(conn, options, {:ok, Update.storage_failed(commands, reason)})
    end
  end

  defp receive_pack(reader, config, repo, commands, options, rest, path) do
    case Body.copy_to_file(reader, rest, path) do
      {:ok, conn} ->
        reply(conn, options, Update.run(conn, config, repo, commands, options, path))

      {:error, reason, conn} ->
        reply(conn, options, Update.unpack_failed(commands, read_error(reason)))
    end
  end

  defp read_error(:too_large), do: "pack too large"
  defp read_error(:bad_gzip), do: "malformed gzip body"
  defp read_error(_reason), do: "cannot read the pack"

  # Step 6: report-status, inner pkt-lines ending in a flush, after any message from
  # `before_update` on band 2, which git prints as `remote:` lines.
  defp reply(conn, options, {unpack, commands}), do: reply(conn, options, {unpack, commands, nil})

  defp reply(conn, options, {unpack, commands, message}) do
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
        options.side_band -> [message(message), PktLine.sideband(1, report), PktLine.flush()]
        true -> report
      end

    HTTP.result(conn, @service, body)
  end

  # Sent as given, split across as many packets as it takes, ending in a newline so
  # git prints its last line.
  defp message(nil), do: []
  defp message(""), do: []

  defp message(text) do
    if String.ends_with?(text, "\n"),
      do: PktLine.sideband(2, text),
      else: PktLine.sideband(2, [text, "\n"])
  end

  # One report line's text, short enough for its pkt-line whatever it quotes.
  defp one_line(text) do
    text = String.replace(text, ~r/[\r\n]/, " ")
    if byte_size(text) > 1000, do: binary_part(text, 0, 1000), else: text
  end
end
