defmodule GitServer.Pack.Merge do
  @moduledoc """
  Merges stored packs into one pack file, keeping every object once, without
  re-deflating what it can copy.

  The inputs are local pack files with their idx files, in order. The kept copy of
  each object is its first: in the earliest input, which holds each object at most
  once. The output holds the kept entries input by input, each in its pack's order:

    * a whole object, and a REF_DELTA whose base's kept copy is in the same input,
      are copied byte for byte;
    * an OFS_DELTA whose base's kept copy is the entry it points to is copied with
      its base offset rewritten to the base's new place, still before it, since
      entries keep their order;
    * any other delta, whose base's kept copy is in an earlier input, is written
      whole: read, resolved and deflated.

  So every delta chain in the output is one that existed inside a single input
  pack, no deeper, and with every base present. Bytes are copied in chunks from one
  input open at a time; only an object written whole is held in memory.

  The output is not trusted by itself: the caller indexes it and compares its ids
  with the inputs' (see `GitServer.Compaction`).
  """

  alias GitServer.ObjectDB
  alias GitServer.ObjectId
  alias GitServer.Pack
  alias GitServer.Pack.Idx
  alias GitServer.Pack.Reader

  @chunk 65_536
  @max_header 40

  @doc """
  Writes the merge of `inputs`, a list of `{pack_path, idx_path}`, to a new file at
  `path`. `read_opts` are `GitServer.ObjectDB`'s, for the objects written whole.
  With `max_bytes`, a pack that would be larger fails with `{:too_large, n}` as
  soon as it gets there, while copying the `n`th input (from 0); an object written
  whole can be far larger than its delta was. Since an input's entries depend only on
  the inputs before it, the first `n` inputs merge within `max_bytes`.
  Returns `{:ok, checksum, ids}`, the pack's trailer checksum and every id the
  inputs' idx files list, or `{:error, reason}`, after which the caller removes
  `path`.
  """
  @spec write([{Path.t(), Path.t()}], Path.t(), keyword, pos_integer | nil) ::
          {:ok, ObjectId.t(), MapSet.t(ObjectId.t())}
          | {:error, String.t() | {:too_large, non_neg_integer}}
  def write(inputs, path, read_opts \\ [], max_bytes \\ nil) do
    # Opening checks every input: each idx against its pack's header, trailer and size.
    with {:ok, db} <- ObjectDB.open(inputs, read_opts) do
      try do
        run(db, inputs, path, max_bytes)
      after
        ObjectDB.close(db)
      end
    end
  end

  defp run(db, inputs, path, max_bytes) do
    packs = Enum.map(Enum.with_index(inputs), &layout/1)

    # The first copy of each id, as {input, offset}.
    kept =
      Enum.reduce(packs, %{}, fn pack, kept ->
        Enum.reduce(pack.entries, kept, fn {offset, _stop, id}, kept ->
          Map.put_new(kept, id, {pack.n, offset})
        end)
      end)

    out =
      case :file.open(path, [:write, :raw, :binary, {:delayed_write, 262_144, 2000}]) do
        {:ok, out} ->
          out

        {:error, posix} ->
          Reader.fail("cannot write the merged pack: #{:file.format_error(posix)}")
      end

    try do
      w = %{out: out, pos: 0, hash: ObjectId.hash_init(), max: max_bytes, input: 0}

      with {:ok, w} <- emit(w, Pack.encode_header(map_size(kept))),
           {:ok, w} <- copy_packs(db, kept, packs, w) do
        checksum = ObjectId.hash_final(w.hash)
        :ok = write!(out, checksum)
        {:ok, checksum, MapSet.new(Map.keys(kept))}
      end
    after
      # A delayed write's error comes back from the close.
      case :file.close(out) do
        :ok ->
          :ok

        {:error, posix} ->
          Reader.fail("cannot write the merged pack: #{:file.format_error(posix)}")
      end
    end
  catch
    # Pack.Reader's abort of a read or write deep in the merge.
    {:pack_error, reason} -> {:error, reason}
  end

  # Each entry's offset, end and id, in pack order.
  defp layout({{pack_path, idx_path}, n}) do
    idx =
      with {:ok, binary} <- File.read(idx_path),
           {:ok, idx} <- Idx.decode(binary) do
        idx
      else
        {:error, posix} when is_atom(posix) ->
          Reader.fail("cannot read pack index: #{:file.format_error(posix)}")

        {:error, reason} ->
          Reader.fail(reason)
      end

    data_end =
      case File.stat(pack_path) do
        {:ok, %{size: size}} -> size - Pack.trailer_size()
        {:error, posix} -> Reader.fail("cannot read pack: #{:file.format_error(posix)}")
      end

    sorted = idx |> Idx.entries() |> Enum.sort_by(&elem(&1, 1))
    stops = Enum.map(Enum.drop(sorted, 1), &elem(&1, 1)) ++ [data_end]
    entries = Enum.zip_with(sorted, stops, fn {id, offset}, stop -> {offset, stop, id} end)
    %{n: n, path: pack_path, entries: entries, ids: Map.new(entries, &{elem(&1, 0), elem(&1, 2)})}
  end

  # Each step returns `{:ok, w}`, or `{:error, {:too_large, input}}` once the output
  # would pass `max_bytes`.
  defp copy_packs(db, kept, packs, w) do
    Enum.reduce_while(packs, {:ok, w}, fn pack, {:ok, w} ->
      case copy_pack(db, kept, pack, w) do
        {:ok, w} -> {:cont, {:ok, w}}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_pack(db, kept, pack, w) do
    case :file.open(pack.path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          copy_entries(db, kept, pack, fd, pack.entries, %{}, %{w | input: pack.n})
        after
          File.close(fd)
        end

      {:error, posix} ->
        Reader.fail("cannot open pack: #{:file.format_error(posix)}")
    end
  end

  # `moved` maps each of this input's kept offsets to its offset in the output.
  defp copy_entries(_db, _kept, _pack, _fd, [], _moved, w) do
    {:ok, w}
  end

  defp copy_entries(db, kept, pack, fd, [{offset, stop, id} | rest], moved, w) do
    if kept[id] == {pack.n, offset} do
      entry = %{offset: offset, stop: stop, id: id}

      with {:ok, next} <- copy_entry(db, kept, pack, fd, moved, entry, w) do
        copy_entries(db, kept, pack, fd, rest, Map.put(moved, offset, w.pos), next)
      end
    else
      copy_entries(db, kept, pack, fd, rest, moved, w)
    end
  end

  defp copy_entry(db, kept, pack, fd, moved, %{offset: offset, stop: stop, id: id}, w) do
    header = Reader.pread(fd, offset, min(@max_header, stop - offset))

    {kind, size, used} =
      case Pack.parse_object_header(header, offset) do
        {:ok, kind, size, used} when offset + used <= stop -> {kind, size, used}
        {:error, reason} -> Reader.fail(reason)
        _ -> Reader.fail("truncated object")
      end

    case kind do
      {:base, _type} ->
        copy(w, fd, offset, stop)

      {:ref, base} ->
        case kept[base] do
          {n, _offset} when n == pack.n -> copy(w, fd, offset, stop)
          _ -> whole(w, db, id)
        end

      {:ofs, base_offset} ->
        base = Map.get(pack.ids, base_offset) || Reader.fail("bad delta base offset")

        if kept[base] == {pack.n, base_offset} do
          # Kept and earlier in this input, so already written, before this entry.
          base_pos = Map.get(moved, base_offset) || Reader.fail("bad delta base offset")

          with {:ok, w} <- emit(w, Pack.encode_ofs_delta_header(size, w.pos - base_pos)) do
            copy(w, fd, offset + used, stop)
          end
        else
          whole(w, db, id)
        end
    end
  end

  defp copy(w, _fd, pos, stop) when pos >= stop do
    {:ok, w}
  end

  defp copy(w, fd, pos, stop) do
    bytes = Reader.pread(fd, pos, min(@chunk, stop - pos))

    with {:ok, w} <- emit(w, bytes) do
      copy(w, fd, pos + byte_size(bytes), stop)
    end
  end

  defp whole(w, db, id) do
    case ObjectDB.read(db, id) do
      {:ok, type, content} ->
        emit(w, [Pack.encode_object_header(type, byte_size(content)), :zlib.compress(content)])

      :error ->
        Reader.fail("missing object #{ObjectId.to_hex(id)}")

      {:error, reason} ->
        Reader.fail(reason)
    end
  end

  defp emit(w, iodata) do
    pos = w.pos + IO.iodata_length(iodata)

    if w.max && pos + Pack.trailer_size() > w.max do
      {:error, {:too_large, w.input}}
    else
      :ok = write!(w.out, iodata)
      {:ok, %{w | pos: pos, hash: ObjectId.hash_update(w.hash, iodata)}}
    end
  end

  defp write!(out, iodata) do
    case :file.write(out, iodata) do
      :ok -> :ok
      {:error, posix} -> Reader.fail("cannot write the merged pack: #{:file.format_error(posix)}")
    end
  end
end
