defmodule GitServer.PackCache do
  @moduledoc """
  A local directory of stored packs and their idx files, so a fetch or push doesn't
  download a pack it has seen before.

  An entry is `<hash>.pack` and `<hash>.idx`, where the hash covers the store's
  `describe/1` and the pack's full key, so two stores or repositories never share a
  file by accident. A pack's key names its checksum and a stored pack never changes,
  so an entry is never stale; it's used only for a pack the current state lists.

  An entry is checked before it goes in: everything `GitServer.ObjectDB.open/2`
  checks of a pack and its idx, plus the pack's SHA-1 over every byte before its
  trailer against the trailer and the pack's name. Files go in under temporary
  names and are renamed into place, idx before pack, so an entry counts as present
  only once its pack is, and no one ever sees a partial file. Requests take entries by hard link into their
  own directory (a copy across file systems), so eviction never pulls a file from
  under a request.

  Eviction is by file, with no process: after a request inserts, it lists the
  directory and removes the least recently used entries (by the pack's modification
  time, set on a hit at most once an hour) until the total is under the cap. Two
  requests racing to insert or evict are harmless, and two servers running as the
  same user may share the directory. The directory and its parents must be private
  to that user and hold nothing else: eviction deletes any `*.pack`, `*.idx` and
  stale `*.tmp-*` file in it.
  """

  alias GitServer.ObjectDB
  alias GitServer.ObjectId
  alias GitServer.Pack
  alias GitServer.Store

  defstruct [:dir, :max_bytes, :store_id]

  @type t :: %__MODULE__{}

  # Temporary files older than this are a crashed insert's.
  @stale_seconds 3600
  @touch_seconds 3600
  @chunk 1_048_576
  @doc """
  Opens the cache in `dir`, creating it private to this user if it doesn't exist:
  `{:ok, cache}` or `{:error, reason}`.
  """
  def open(dir, max_bytes, store) do
    with :ok <- mkdir(dir) do
      {:ok, %__MODULE__{dir: dir, max_bytes: max_bytes, store_id: Store.describe(store)}}
    end
  end

  defp mkdir(dir) do
    result =
      cond do
        File.dir?(dir) -> :ok
        (result = File.mkdir_p(dir)) != :ok -> result
        true -> File.chmod(dir, 0o700)
      end

    with {:error, posix} <- result,
         do: {:error, "cannot use the pack cache #{dir}: #{:file.format_error(posix)}"}
  end

  @doc """
  Puts the entry for the pack at `key` into `pack_path` and `idx_path`, which must not
  exist: `:ok`, or `:miss` with neither file left behind.
  """
  def take(%__MODULE__{} = cache, key, pack_path, idx_path) do
    {pack, idx} = entry_paths(cache, key)

    with :ok <- link_or_copy(idx, idx_path),
         :ok <- link_or_undo(pack, pack_path, idx_path) do
      touch(pack)
      :ok
    else
      _ -> :miss
    end
  end

  # A pack's modification time is its entry's place in the eviction order. Setting it
  # is slow on some file systems, so it's set at most once an hour.
  defp touch(pack) do
    now = System.os_time(:second)

    case File.stat(pack, time: :posix) do
      # Unlike File.touch, never creates the file if an evictor just removed it.
      {:ok, %{mtime: mtime} = stat} when now - mtime > @touch_seconds ->
        File.write_stat(pack, %{stat | mtime: now}, time: :posix)

      _ ->
        :ok
    end
  end

  defp link_or_undo(source, target, undo) do
    with {:error, _} = error <- link_or_copy(source, target) do
      File.rm(undo)
      error
    end
  end

  defp link_or_copy(source, target) do
    case File.ln(source, target) do
      :ok -> :ok
      {:error, :exdev} -> copy(source, target)
      {:error, posix} -> {:error, posix}
    end
  end

  defp copy(source, target) do
    case File.cp(source, target) do
      :ok ->
        :ok

      {:error, posix} ->
        File.rm(target)
        {:error, posix}
    end
  end

  @doc """
  Checks the downloaded pack named `name` (its checksum in hex) against its idx and
  adds it as the entry for `key`: `:ok` or `{:error, reason}` if the files don't
  check. Failing to write the cache isn't an error: the request has its files.
  """
  def insert(%__MODULE__{} = cache, key, name, pack_path, idx_path) do
    with :ok <- verify(name, pack_path, idx_path) do
      {pack, idx} = entry_paths(cache, key)

      # A failed write leaves at most an idx without its pack, which is a miss.
      if place(idx_path, idx) == :ok, do: place(pack_path, pack)
      :ok
    end
  end

  defp place(source, target) do
    temp = "#{target}.tmp-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"

    with :ok <- link_or_copy(source, temp),
         :ok <- File.rename(temp, target) do
      :ok
    else
      error ->
        File.rm(temp)
        error
    end
  end

  # The checks an entry passes before it goes in: what ObjectDB.open checks of a pack
  # and its idx, plus the pack's SHA-1 over every byte before its trailer, against
  # the trailer and the name.
  defp verify(name, pack_path, idx_path) do
    with {:ok, checksum} <- pack_checksum(pack_path),
         true <-
           Base.encode16(checksum, case: :lower) == name ||
             {:error, "pack doesn't match its name"},
         {:ok, db} <- ObjectDB.open([{pack_path, idx_path}]) do
      ObjectDB.close(db)
      :ok
    else
      {:error, posix} when is_atom(posix) ->
        {:error, "cannot read a downloaded pack: #{:file.format_error(posix)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The SHA-1 over everything before the trailer, if it equals the trailer.
  defp pack_checksum(path) do
    trailer = Pack.trailer_size()

    with {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        with {:ok, size} <- :file.position(fd, :eof),
             true <- size >= Pack.header_size() + trailer || {:error, "truncated pack"},
             {:ok, hash} <- hash(fd, 0, size - trailer, ObjectId.hash_init()),
             {:ok, stored} <- :file.pread(fd, size - trailer, trailer) do
          if stored == hash, do: {:ok, hash}, else: {:error, "pack checksum mismatch"}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, "truncated pack"}
        end
      after
        File.close(fd)
      end
    end
  end

  defp hash(_fd, pos, stop, state) when pos >= stop do
    {:ok, ObjectId.hash_final(state)}
  end

  defp hash(fd, pos, stop, state) do
    case :file.pread(fd, pos, min(@chunk, stop - pos)) do
      {:ok, bytes} -> hash(fd, pos + byte_size(bytes), stop, ObjectId.hash_update(state, bytes))
      _ -> {:error, "truncated pack"}
    end
  end

  @doc """
  Removes the least recently used entries until the cache is under its cap, and
  temporary files left by a crashed insert.
  """
  def evict(%__MODULE__{dir: dir, max_bytes: max_bytes}) do
    now = System.os_time(:second)

    files =
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    {entries, total} =
      Enum.reduce(files, {%{}, 0}, fn file, {entries, total} ->
        path = Path.join(dir, file)

        case {Path.extname(file), File.stat(path, time: :posix)} do
          {_, {:error, _}} ->
            {entries, total}

          {ext, {:ok, stat}} when ext in [".pack", ".idx"] ->
            hash = Path.rootname(file)
            entry = Map.get(entries, hash, %{bytes: 0, mtime: nil})
            mtime = if ext == ".pack", do: stat.mtime, else: entry.mtime

            {Map.put(entries, hash, %{bytes: entry.bytes + stat.size, mtime: mtime}),
             total + stat.size}

          {_, {:ok, stat}} ->
            if String.contains?(file, ".tmp-") and now - stat.mtime > @stale_seconds,
              do: File.rm(path)

            {entries, total}
        end
      end)

    # An idx without its pack is a crashed insert or one in flight: oldest first.
    entries
    |> Enum.sort_by(fn {_hash, entry} -> entry.mtime || 0 end)
    |> Enum.reduce_while(total, fn {hash, entry}, total ->
      if total <= max_bytes do
        {:halt, total}
      else
        File.rm(Path.join(dir, hash <> ".pack"))
        File.rm(Path.join(dir, hash <> ".idx"))
        {:cont, total - entry.bytes}
      end
    end)

    :ok
  end

  defp entry_paths(%__MODULE__{dir: dir, store_id: store_id}, key) do
    hash = Base.encode16(:crypto.hash(:sha256, [store_id, 0, key]), case: :lower)
    {Path.join(dir, hash <> ".pack"), Path.join(dir, hash <> ".idx")}
  end
end
