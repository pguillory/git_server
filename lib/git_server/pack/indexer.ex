defmodule GitServer.Pack.Indexer do
  @moduledoc """
  Indexes an incoming pack file: checks it, resolves every delta, computes every
  object's id, type and links, and builds its idx.

  Bases of deltas must be inside the pack: a REF_DELTA whose base isn't (a thin pack)
  fails the whole pack. Every limit is an option, for packs from any authorized writer:

    * `:max_pack_bytes` - the pack file's size (default 100 MB)
    * `:max_object_bytes` - an object's inflated size, and a delta's (default 50 MB)
    * `:max_objects` - objects in the pack (default 100,000)
    * `:max_links` - links (a commit's tree and parents, a tree's entries, a tag's
      target) across the whole pack, since every object's links are kept for the
      caller (default 1,000,000)
    * `:max_work_bytes` - bytes inflated and produced by deltas, in all, including
      re-resolving delta bases the cache couldn't keep (default 2 GB), so a pack
      crafted to make indexing slow fails instead
    * `:max_delta_depth` - the longest delta chain (default 100)
    * `:cache_bytes` - the resolved-base cache (default 32 MB)

  It runs in two passes. Pass 1 reads the objects in order, recording each one's
  offset, kind and size, and the id of each whole object. Its zlib stream's end isn't
  recorded anywhere, so it is found as described at `find_end`. Pass 2 resolves the
  deltas, each chain iteratively; a delta waits when its REF_DELTA base comes later in
  the pack.
  """

  alias GitServer.{Object, ObjectId, Pack}
  alias GitServer.Pack.{Cache, Idx, Reader}

  @chunk 65_536
  @max_header 40
  @max_rejected 8

  @defaults [
    max_pack_bytes: 100_000_000,
    max_object_bytes: 50_000_000,
    max_objects: 100_000,
    max_links: 1_000_000,
    max_work_bytes: 2_000_000_000,
    max_delta_depth: 100,
    cache_bytes: 32_000_000,
  ]

  @typedoc """
  The indexed pack: its checksum (and so its name), its idx, and each object's type and
  typed links (see `GitServer.Object.parse_links/2`).
  """
  @type result :: %{
          checksum: ObjectId.t(),
          idx: binary,
          objects: %{ObjectId.t() => {Object.type(), [Object.link()]}},
        }

  @doc "The default limits."
  def defaults, do: @defaults

  @doc "Indexes the pack file at `path`."
  @spec index(Path.t(), keyword) :: {:ok, result} | {:error, String.t()}
  def index(path, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        cache = Cache.new(opts[:cache_bytes])

        try do
          {:ok, run(fd, cache, opts)}
        catch
          {:pack_error, reason} -> {:error, reason}
        after
          Cache.delete(cache)
          File.close(fd)
        end

      {:error, reason} ->
        {:error, "cannot open pack: #{:file.format_error(reason)}"}
    end
  end

  defp run(fd, cache, opts) do
    {:ok, size} = :file.position(fd, :eof)
    trailer = Pack.trailer_size()
    if size > opts[:max_pack_bytes], do: Reader.fail("pack too large")
    if size < Pack.header_size() + trailer, do: Reader.fail("truncated pack")

    data_end = size - trailer
    checksum = Reader.pread(fd, data_end, trailer)

    if checksum(fd, 0, data_end, ObjectId.hash_init()) != checksum,
      do: Reader.fail("pack checksum mismatch")

    count =
      case Pack.parse_header(Reader.pread(fd, 0, Pack.header_size())) do
        {:ok, count} -> count
        {:error, reason} -> Reader.fail(reason)
      end

    if count > opts[:max_objects], do: Reader.fail("too many objects")

    budget = Reader.new_budget(opts[:max_work_bytes])
    opts = Keyword.put(opts, :budget, budget)

    {entries, ids, left} =
      pass1(fd, Pack.header_size(), data_end, count, opts, %{}, %{}, opts[:max_links])

    reader = %Reader{
      fd: fd,
      ends: Map.new(entries, fn {offset, e} -> {offset, e.stop} end),
      ref: nil,
      budget: budget,
      cache: cache,
      max_object_bytes: opts[:max_object_bytes],
      max_delta_depth: opts[:max_delta_depth],
    }

    deltas = for {offset, e} <- Enum.sort(entries), not Map.has_key?(e, :id), do: offset
    entries = pass2(reader, deltas, entries, ids, %{}, left)

    idx_entries = Enum.map(entries, fn {offset, e} -> {e.id, offset, e.crc} end)

    %{
      checksum: checksum,
      idx: Idx.encode(idx_entries, checksum),
      objects: Map.new(entries, fn {_offset, e} -> {e.id, {e.type, e.links}} end),
    }
  end

  defp checksum(_fd, pos, stop, hash) when pos >= stop, do: ObjectId.hash_final(hash)

  defp checksum(fd, pos, stop, hash) do
    len = min(1_048_576, stop - pos)
    checksum(fd, pos + len, stop, ObjectId.hash_update(hash, Reader.pread(fd, pos, len)))
  end

  # Pass 1: each object in order, its end found from its zlib stream.
  defp pass1(_fd, pos, data_end, 0, _opts, entries, ids, left) do
    if pos != data_end, do: Reader.fail("pack has trailing data")
    {entries, ids, left}
  end

  defp pass1(_fd, pos, data_end, _count, _opts, _entries, _ids, _left) when pos >= data_end,
    do: Reader.fail("truncated pack")

  defp pass1(fd, offset, data_end, count, opts, entries, ids, left) do
    header = Reader.pread(fd, offset, min(@max_header, data_end - offset))
    max_object_bytes = opts[:max_object_bytes]

    {kind, size, used} =
      case Pack.parse_object_header(header, offset) do
        {:ok, _kind, size, _used} when size > max_object_bytes ->
          Reader.fail("object too large")

        {:ok, kind, size, used} ->
          {kind, size, used}

        :more ->
          Reader.fail("truncated pack")

        {:error, reason} ->
          Reader.fail(reason)
      end

    # An OFS_DELTA base must be the start of an earlier object.
    case kind do
      {:ofs, base} when not is_map_key(entries, base) -> Reader.fail("bad delta base offset")
      _ -> :ok
    end

    start = offset + used
    crc0 = :erlang.crc32(binary_part(header, 0, used))
    e = %{start: start, size: size, kind: kind, budget: opts[:budget]}
    {stop, crc, sink} = find_end(fd, e, data_end, crc0)
    e = %{kind: kind, size: size, start: start, stop: stop, crc: crc}

    {e, ids, left} =
      case kind do
        {:base, type} ->
          id = ObjectId.hash_final(sink.hash)
          {links, left} = links(type, IO.iodata_to_binary(Enum.reverse(sink.content)), id, left)
          {Map.merge(e, %{id: id, type: type, links: links}), add_id(ids, id, offset), left}

        _delta ->
          {e, ids, left}
      end

    pass1(fd, stop, data_end, count - 1, opts, Map.put(entries, offset, e), ids, left)
  end

  defp add_id(ids, id, offset) do
    if Map.has_key?(ids, id), do: Reader.fail("duplicate object #{ObjectId.to_hex(id)}")
    Map.put(ids, id, offset)
  end

  defp links(type, content, id, left) do
    case Object.parse_links(type, content, left) do
      {:ok, links} -> {links, left - length(links)}
      {:error, "too many links"} -> Reader.fail("too many links")
      {:error, reason} -> Reader.fail("#{reason} #{ObjectId.to_hex(id)}")
    end
  end

  # Pass 2: resolve deltas in pack order. A delta whose chain reaches a REF_DELTA base
  # that isn't known yet waits on that id, and is retried once an object with that id
  # is resolved, so each delta is retried at most once per REF_DELTA in its chain.
  # Deltas still waiting at the end have bases that aren't in the pack.
  defp pass2(_reader, [], entries, _ids, waiting, _left) do
    if waiting != %{}, do: Reader.fail("thin pack not supported")
    entries
  end

  defp pass2(reader, [offset | pending], entries, ids, waiting, left) do
    case resolve(reader, offset, ids) do
      {:waiting, id} ->
        waiting = Map.update(waiting, id, [offset], &[offset | &1])
        pass2(reader, pending, entries, ids, waiting, left)

      {type, content} ->
        id = Object.id(type, content)
        {links, left} = links(type, content, id, left)
        e = Map.merge(entries[offset], %{id: id, type: type, links: links})
        {ready, waiting} = Map.pop(waiting, id, [])
        ids = add_id(ids, id, offset)
        pass2(reader, ready ++ pending, Map.put(entries, offset, e), ids, waiting, left)
    end
  end

  defp resolve(reader, offset, ids) do
    Reader.read(%{reader | ref: &Map.fetch(ids, &1)}, offset)
  catch
    {:missing_base, id} -> {:waiting, id}
  end

  # Finds where an incoming object's zlib stream ends, since `:zlib` drops input past
  # the end of a stream without saying how much it used.
  #
  # The stream is fed in chunks (first a window that holds a whole normal stream, up
  # to 64 KB, then 64 KB at a time) while keeping the Adler-32 of the output. Once the
  # output reaches the declared size, the stream must end with that Adler-32,
  # big-endian (RFC 1950), somewhere in the bytes fed so far or soon after. Every place
  # those 4 bytes occur, overlapping ones included, in order, is a candidate end,
  # confirmed by inflating exactly up to it with a fresh inflater, which must reach the
  # end of the stream with the declared size. The first that passes is the end. More
  # than 8 false candidates in one object fail it. Returns `{stop, crc, sink}`:
  # the end, the CRC-32 of the object's raw bytes (`crc0` covers its header), and for
  # a whole object its hash (and, for commits, trees and tags, its content).
  defp find_end(fd, e, data_end, crc0) do
    Reader.charge(e.budget, e.size)

    sink =
      case e.kind do
        {:base, type} ->
          %{
            hash: ObjectId.hash_update(ObjectId.hash_init(), Object.header(type, e.size)),
            keep: type != :blob,
            content: [],
          }

        _delta ->
          %{hash: nil, keep: false, content: []}
      end

    window = min(e.size + div(e.size, 4096) + 64, @chunk)

    state = %{
      pos: e.start,
      len: window,
      n: 0,
      adler: :erlang.adler32(<<>>),
      complete: nil,
      rejected: 0,
      sink: sink,
    }

    Reader.with_inflater(fn z -> feed(fd, z, e, data_end, crc0, state) end)
  end

  defp feed(fd, z, e, data_end, crc0, state) do
    len = min(state.len, data_end - state.pos)
    if len == 0, do: Reader.fail("truncated pack")
    feed_start = state.pos
    state = drain(z, Reader.safe_inflate(z, Reader.pread(fd, feed_start, len)), e.size, state)
    state = %{state | pos: feed_start + len, len: @chunk}

    # The trailer comes after the last output byte's input, so it can't start before
    # this feed, less a few bytes zlib may have read ahead (16 is generous). Later
    # searches start 3 bytes back, in case the trailer straddles two feeds.
    state =
      if state.complete == nil and state.n == e.size,
        do: %{state | complete: max(e.start, feed_start - 16)},
        else: state

    if state.complete do
      from = state.complete
      region = Reader.pread(fd, from, state.pos - from)
      candidates = for p <- matches(region, <<state.adler::32>>, 0), do: from + p + 4

      case first_confirmed(fd, e, candidates, crc0, state.rejected) do
        {:rejected, rejected} ->
          state = %{state | complete: max(e.start, state.pos - 3), rejected: rejected}
          feed(fd, z, e, data_end, crc0, state)

        {stop, crc} ->
          {stop, crc, state.sink}
      end
    else
      feed(fd, z, e, data_end, crc0, state)
    end
  end

  defp drain(z, {status, out}, size, state) do
    n = state.n + IO.iodata_length(out)
    if n > size, do: Reader.fail("object size mismatch")
    sink = state.sink
    sink = if sink.hash, do: %{sink | hash: ObjectId.hash_update(sink.hash, out)}, else: sink
    sink = if sink.keep, do: %{sink | content: [out | sink.content]}, else: sink
    state = %{state | n: n, adler: :erlang.adler32(state.adler, out), sink: sink}
    if status == :continue, do: drain(z, Reader.safe_inflate(z, []), size, state), else: state
  end

  # Every position of `pattern`, overlapping ones too (`:binary.matches/2` skips those,
  # and the real trailer can overlap a false match).
  defp matches(region, pattern, from) do
    case :binary.match(region, pattern, scope: {from, byte_size(region) - from}) do
      {p, _} -> [p | matches(region, pattern, p + 1)]
      :nomatch -> []
    end
  end

  # A false candidate is about a 1 in 65,536 chance per 64 KB, so a stream with many is
  # crafted to make each object cost many inflations, and is refused.
  defp first_confirmed(_fd, _e, _candidates, _crc0, rejected) when rejected > @max_rejected,
    do: Reader.fail("corrupt object")

  defp first_confirmed(_fd, _e, [], _crc0, rejected), do: {:rejected, rejected}

  defp first_confirmed(fd, e, [stop | rest], crc0, rejected) do
    Reader.charge(e.budget, max(e.size, stop - e.start))

    case confirm(fd, e, stop, crc0) do
      nil -> first_confirmed(fd, e, rest, crc0, rejected + 1)
      found -> found
    end
  end

  # Inflates exactly the bytes up to `stop` with a fresh inflater, which must reach
  # the end of the stream with the declared size.
  defp confirm(fd, e, stop, crc0) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z)
      {n, crc} = confirm_feed(fd, z, e.start, stop, e.size, 0, crc0)
      :zlib.inflateEnd(z)
      if n == e.size, do: {stop, crc}
    rescue
      error in ErlangError ->
        if match?(%ErlangError{original: :data_error}, error),
          do: nil,
          else: reraise(error, __STACKTRACE__)
    catch
      :too_long -> nil
    after
      :zlib.close(z)
    end
  end

  defp confirm_feed(_fd, _z, pos, stop, _size, n, crc) when pos >= stop, do: {n, crc}

  defp confirm_feed(fd, z, pos, stop, size, n, crc) do
    bytes = Reader.pread(fd, pos, min(@chunk, stop - pos))
    n = confirm_drain(z, Reader.safe_inflate(z, bytes), size, n)
    confirm_feed(fd, z, pos + byte_size(bytes), stop, size, n, :erlang.crc32(crc, bytes))
  end

  defp confirm_drain(z, {status, out}, size, n) do
    n = n + IO.iodata_length(out)
    if n > size, do: throw(:too_long)
    if status == :continue, do: confirm_drain(z, Reader.safe_inflate(z, []), size, n), else: n
  end
end
