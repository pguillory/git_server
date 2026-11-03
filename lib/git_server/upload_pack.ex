defmodule GitServer.UploadPack do
  @moduledoc """
  The commands of protocol v2's `git-upload-pack`: `ls-refs` and `fetch`
  (gitprotocol-v2). Each is one stateless request, and works from the repository's
  state as it is when that request reads it.

  A fetch sends everything reachable from its wants, minus everything reachable from
  the haves the repository contains, as a pack of whole objects streamed on side-band
  1. Wants must be reachable from the current refs. Without `done`, any known have
  makes the server `ready`, which may send more than git's own upload-pack would but
  is always correct. Shallow fetches (`shallow`, `deepen`, `deepen-relative`,
  `deepen-since`) follow git's upload-pack (see `GitServer.Shallow`); `deepen-not` is
  refused.

  An error before the response starts is an `ERR` packet, which git prints as
  `fatal: remote error: <text>`: a POST's HTTP error status reaches the user only as
  `RPC failed`. A store failure is logged and the client told only that the server's
  storage failed. An error while the pack is going out is a fatal message on
  side-band 3.
  """

  import Plug.Conn, only: [chunk: 2]

  alias GitServer.{
    Config,
    HTTP,
    Object,
    ObjectDB,
    ObjectId,
    ObjectWalk,
    PktLine,
    Repository,
    Shallow
  }

  alias GitServer.Pack.Writer

  @service "git-upload-pack"
  @max_depth Shallow.max_depth()

  @doc """
  Answers a v2 request body: `command=<name>`, capabilities, a delim, arguments, a
  flush. Returns the sent conn.
  """
  def command(conn, config, repo, body) do
    with {:ok, packets} <- PktLine.decode(body),
         {:ok, command, capabilities, arguments} <- split_command(packets),
         :ok <- check_capabilities(capabilities) do
      case command do
        "ls-refs" -> ls_refs(conn, config, repo, arguments)
        "fetch" -> fetch(conn, config, repo, arguments)
        other -> error(conn, "unknown command #{inspect(other)}")
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp split_command(["command=" <> command | rest]) do
    {capabilities, rest} = Enum.split_while(rest, &is_binary/1)

    case rest do
      [:flush] ->
        {:ok, PktLine.chomp(command), Enum.map(capabilities, &PktLine.chomp/1), []}

      [:delim | rest] ->
        case Enum.split_while(rest, &is_binary/1) do
          {arguments, [:flush]} ->
            {:ok, PktLine.chomp(command), Enum.map(capabilities, &PktLine.chomp/1),
             Enum.map(arguments, &PktLine.chomp/1)}

          _ ->
            {:error, "malformed request"}
        end

      _ ->
        {:error, "malformed request"}
    end
  end

  defp split_command(_packets) do
    {:error, "malformed request"}
  end

  defp check_capabilities(capabilities) do
    Enum.reduce_while(capabilities, :ok, fn
      "agent=" <> _, :ok -> {:cont, :ok}
      "object-format=sha1", :ok -> {:cont, :ok}
      "object-format=" <> format, :ok -> {:halt, {:error, "unsupported object-format #{format}"}}
      other, :ok -> {:halt, {:error, "unsupported capability #{inspect(other)}"}}
    end)
  end

  defp ls_refs(conn, config, repo, arguments) do
    with {:ok, options} <- ls_refs_options(arguments),
         {:ok, state, _etag} <- Repository.read_state(config.store, repo) do
      # Reading tags means downloading the packs, so only when a listed ref could be one.
      if options.peel and Enum.any?(listed_refs(state, options), &peelable?(elem(&1, 0))) do
        with_objects(conn, config, repo, fn snapshot, db ->
          send_refs(conn, snapshot.state, options, &peeled(db, &1))
        end)
      else
        send_refs(conn, state, options, nil)
      end
    else
      {:error, :bad_argument, argument} ->
        error(conn, "unsupported ls-refs argument #{inspect(argument)}")

      {:error, reason} ->
        storage_error(conn, reason)
    end
  end

  defp ls_refs_options(arguments) do
    initial = %{symrefs: false, unborn: false, peel: false, prefixes: []}

    Enum.reduce_while(arguments, {:ok, initial}, fn
      "symrefs", {:ok, options} ->
        {:cont, {:ok, %{options | symrefs: true}}}

      "unborn", {:ok, options} ->
        {:cont, {:ok, %{options | unborn: true}}}

      "peel", {:ok, options} ->
        {:cont, {:ok, %{options | peel: true}}}

      "ref-prefix " <> prefix, {:ok, options} ->
        {:cont, {:ok, %{options | prefixes: [prefix | options.prefixes]}}}

      other, _ ->
        {:halt, {:error, :bad_argument, other}}
    end)
  end

  defp send_refs(conn, state, options, peel) do
    symref = if options.symrefs, do: " symref-target:#{state.head}", else: ""

    head =
      cond do
        not wanted?(options, "HEAD") ->
          []

        id = state.refs[state.head] ->
          [
            PktLine.encode("#{id} HEAD#{symref}#{peeled_attribute(state.head, id, peel)}\n"),
          ]

        options.unborn ->
          [PktLine.encode("unborn HEAD#{symref}\n")]

        true ->
          []
      end

    refs =
      for {name, id} <- listed_refs(state, options) do
        PktLine.encode("#{id} #{name}#{peeled_attribute(name, id, peel)}\n")
      end

    HTTP.result(conn, @service, [head, refs, PktLine.flush()])
  end

  defp listed_refs(state, options) do
    state.refs |> Enum.sort() |> Enum.filter(fn {name, _id} -> wanted?(options, name) end)
  end

  defp wanted?(options, name) do
    options.prefixes == [] or Enum.any?(options.prefixes, &String.starts_with?(name, &1))
  end

  # Branches hold commits, so only other refs can name a tag object.
  defp peelable?(name) do
    not String.starts_with?(name, "refs/heads/")
  end

  defp peeled_attribute(_name, _id, nil) do
    ""
  end

  defp peeled_attribute(name, id, peel) do
    target = if peelable?(name), do: peel.(id)
    if target, do: " peeled:#{target}", else: ""
  end

  # The object a tag ref finally points to, in hex, or nil if the ref isn't an annotated
  # tag. The attribute is optional, so a tag that can't be read just goes without.
  defp peeled(db, hex) do
    with {:ok, id} <- ObjectId.from_hex(hex),
         {:ok, :tag, _size} <- ObjectDB.lookup(db, id) do
      follow_tag(db, id, Object.max_peel())
    else
      _ -> nil
    end
  end

  # A chain longer than the bound goes without, like an unreadable tag.
  defp follow_tag(_db, _id, 0), do: nil

  defp follow_tag(db, id, n) do
    with {:ok, :tag, content} <- ObjectDB.read(db, id),
         {:ok, [{type, target}]} <- ObjectDB.parse_links(:tag, content) do
      if type == :tag, do: follow_tag(db, target, n - 1), else: ObjectId.to_hex(target)
    else
      _ -> nil
    end
  end

  defp fetch(conn, config, repo, arguments) do
    case fetch_request(arguments) do
      {:ok, request} ->
        with_objects(conn, config, repo, fn snapshot, db ->
          negotiate(conn, snapshot.state, db, request)
        end)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  # thin-pack and ofs-delta only permit what we never send, and git follows tags with
  # a fetch of its own when include-tag goes unanswered.
  defp fetch_request(arguments) do
    initial = %{
      wants: [],
      haves: [],
      done: false,
      shallows: [],
      depth: nil,
      relative: false,
      since: nil,
    }

    result =
      Enum.reduce_while(arguments, {:ok, initial}, fn
        "want " <> hex, {:ok, request} ->
          add_id(request, :wants, hex, "want")

        "have " <> hex, {:ok, request} ->
          add_id(request, :haves, hex, "have")

        "done", {:ok, request} ->
          {:cont, {:ok, %{request | done: true}}}

        "shallow " <> hex, {:ok, request} ->
          add_id(request, :shallows, hex, "shallow")

        "deepen " <> n, {:ok, request} ->
          case parse_number(n, 10) do
            {:ok, depth} when depth >= 1 and depth <= @max_depth ->
              {:cont, {:ok, %{request | depth: depth}}}

            _ ->
              {:halt, {:error, "invalid deepen #{inspect(n)}"}}
          end

        "deepen-relative", {:ok, request} ->
          {:cont, {:ok, %{request | relative: true}}}

        "deepen-since " <> time, {:ok, request} ->
          case parse_number(time, 19) do
            {:ok, since} -> {:cont, {:ok, %{request | since: since}}}
            :error -> {:halt, {:error, "invalid deepen-since #{inspect(time)}"}}
          end

        "deepen-not " <> _, _ ->
          {:halt, {:error, "deepen-not (--shallow-exclude) is not supported"}}

        ignored, {:ok, request} when ignored in ~w(thin-pack no-progress include-tag ofs-delta) ->
          {:cont, {:ok, request}}

        other, _ ->
          {:halt, {:error, "unsupported fetch argument #{inspect(other)}"}}
      end)

    case result do
      {:ok, %{wants: []}} ->
        {:error, "fetch needs at least one want"}

      {:ok, %{depth: depth, since: since}} when depth != nil and since != nil ->
        {:error, "deepen and deepen-since cannot be used together"}

      {:ok, request} ->
        {:ok,
         %{
           request
           | wants: Enum.uniq(request.wants),
             haves: Enum.uniq(request.haves),
             shallows: request.shallows |> Enum.reverse() |> Enum.uniq(),
         }}

      error ->
        error
    end
  end

  defp add_id(request, key, hex, label) do
    case ObjectId.from_hex(hex) do
      {:ok, id} -> {:cont, {:ok, Map.update!(request, key, &[id | &1])}}
      :error -> {:halt, {:error, "malformed #{label} #{inspect(hex)}"}}
    end
  end

  # A decimal number of at most `digits` digits.
  defp parse_number(text, digits) do
    if byte_size(text) <= digits and String.match?(text, ~r/\A[0-9]+\z/),
      do: {:ok, String.to_integer(text)},
      else: :error
  end

  defp negotiate(conn, state, db, request) do
    common = Enum.filter(request.haves, &ObjectDB.member?(db, &1))

    with {:ok, shallows} <- Shallow.client_shallows(db, request.shallows),
         :ok <- check_wants(db, state, request.wants) do
      request = %{request | shallows: shallows}

      cond do
        request.done -> send_pack(conn, state, db, request, common, [])
        common != [] -> send_pack(conn, state, db, request, common, acknowledgments(common))
        true -> HTTP.result(conn, @service, nak())
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Both walks stop at the shallow cut; an unshallowed commit's parents are wanted and
  # the commit itself, which the client has, is not.
  defp objects(db, wants, common, shallow) do
    with {:ok, excluded} <-
           ObjectWalk.reachable(db, common ++ shallow.unshallow, MapSet.new(), shallow.cut) do
      ObjectWalk.reachable(
        db,
        wants ++ shallow.unshallow_parents,
        MapSet.new(excluded),
        shallow.cut
      )
    end
  end

  # A want at a ref tip passes at once. Anything else takes a walk of the whole graph.
  defp check_wants(db, state, wants) do
    tips = state.refs |> Map.values() |> Enum.uniq() |> Enum.map(&tip_id/1)
    others = wants -- tips
    absent = Enum.find(others, &(not ObjectDB.member?(db, &1)))

    cond do
      absent -> not_our_ref(absent)
      others == [] -> :ok
      true -> check_reachable(db, tips, others)
    end
  end

  defp check_reachable(db, tips, others) do
    case ObjectWalk.find(db, tips, MapSet.new(others)) do
      {:ok, not_found} ->
        if MapSet.size(not_found) == 0, do: :ok, else: not_our_ref(Enum.at(not_found, 0))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp not_our_ref(id) do
    {:error, "upload-pack: not our ref #{ObjectId.to_hex(id)}"}
  end

  defp tip_id(hex) do
    {:ok, id} = ObjectId.from_hex(hex)
    id
  end

  defp acknowledgments(common) do
    [
      PktLine.encode("acknowledgments\n"),
      Enum.map(common, &PktLine.encode("ACK #{ObjectId.to_hex(&1)}\n")),
      PktLine.encode("ready\n"),
      PktLine.delim(),
    ]
  end

  defp shallow_info(%Shallow{info: false}), do: []

  defp shallow_info(shallow) do
    [
      PktLine.encode("shallow-info\n"),
      Enum.map(shallow.shallow, &PktLine.encode("shallow #{ObjectId.to_hex(&1)}\n")),
      Enum.map(shallow.unshallow, &PktLine.encode("unshallow #{ObjectId.to_hex(&1)}\n")),
      PktLine.delim(),
    ]
  end

  defp nak do
    [PktLine.encode("acknowledgments\n"), PktLine.encode("NAK\n"), PktLine.flush()]
  end

  # The object set is settled before the response starts, so a problem with it is
  # still an ERR packet. A client gone mid-pack needs no answer, just no more work.
  defp send_pack(conn, state, db, request, common, preamble) do
    tips = state.refs |> Map.values() |> Enum.uniq() |> Enum.map(&tip_id/1)

    with {:ok, shallow} <- Shallow.plan(db, tips, request.wants, request.shallows, request),
         {:ok, ids} <- objects(db, request.wants, common, shallow) do
      stream_pack(conn, db, ids, [preamble, shallow_info(shallow)])
    else
      {:error, reason} -> error(conn, reason)
    end
  catch
    {:client_gone, conn} -> conn
  end

  defp stream_pack(conn, db, ids, preamble) do
    conn = HTTP.chunked_result(conn, @service)
    conn = send_chunk(conn, [preamble, PktLine.encode("packfile\n")])
    emit = fn piece, conn -> send_chunk(conn, PktLine.sideband(1, piece)) end

    case Writer.write(db, ids, conn, emit) do
      {:ok, _checksum, conn} ->
        send_chunk(conn, PktLine.flush())

      {:error, reason, conn} ->
        send_chunk(conn, [PktLine.sideband(3, "git_server: #{reason}\n"), PktLine.flush()])
    end
  end

  defp send_chunk(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _reason} -> throw({:client_gone, conn})
    end
  end

  # Runs `fun` on the repository's objects, downloaded for this request and deleted
  # afterwards whatever happens. `fun` sends the response.
  defp with_objects(conn, config, repo, fun) do
    result =
      Repository.with_snapshot(config.store, repo, config.temp_dir, fn snapshot ->
        with {:ok, db} <-
               ObjectDB.open(snapshot.packs, Config.read_options(config, repo, fetch: true)) do
          try do
            fun.(snapshot, db)
          after
            ObjectDB.close(db)
          end
        end
      end)

    case result do
      {:error, reason} -> storage_error(conn, reason)
      sent -> sent
    end
  end

  @doc """
  Answers a request whose body couldn't be read (see `GitServer.Body`) with an `ERR`
  packet, since git shows a POST's HTTP error body to no one.
  """
  # The rest of the body goes unread, so the connection is closed after the reply.
  def body_error(conn, :too_large, config) do
    conn = Plug.Conn.put_resp_header(conn, "connection", "close")
    error(conn, "request too large (limit #{Config.format_bytes(config.max_request_bytes)})")
  end

  def body_error(conn, :bad_gzip, _config), do: error(conn, "malformed gzip request body")

  def body_error(conn, :unsupported_encoding, _config),
    do: error(conn, "unsupported Content-Encoding")

  def body_error(conn, _reason, _config), do: error(conn, "could not read the request body")

  # The reason is logged; the client hears only that storage failed.
  defp storage_error(conn, reason) do
    HTTP.log_store_error(reason)
    error(conn, HTTP.storage_failed())
  end

  defp error(conn, reason) do
    HTTP.result(conn, @service, PktLine.error(reason))
  end
end
