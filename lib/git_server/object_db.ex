defmodule GitServer.ObjectDB do
  @moduledoc """
  Reads objects from a set of local pack files, each with its idx.

  Open it in the process that will use it: it holds that process's file handles and a
  private cache of resolved delta bases, and both go away with the process or with
  `close/1`. However many packs it reads, it keeps at most `:max_open_files` of them
  open at once, reopening others as reads reach them. Nothing here raises on a
  hostile or corrupt pack; errors come back as `{:error, reason}` with a
  human-readable reason.

  Options, for `open/2`:

    * `:max_object_bytes` - the largest object (or delta) to inflate (default 50 MB)
    * `:max_delta_depth` - the longest delta chain to follow (default 100)
    * `:cache_bytes` - the size of the resolved-base cache (default 32 MB)
    * `:max_open_files` - the most pack files held open at once (default 16)
    * `:max_base_work_bytes` - a cap on the work of resolving delta bases under the
      objects read (bytes inflated and produced by deltas: what cache misses cost,
      never the work of producing the objects themselves), across every read. Each
      object read raises the cap by twice `max_delta_depth` times its size, so a chain
      read in full, whose re-resolution grows with its depth and the bytes it
      yields, stays within it, while bases resolved again and again for little
      output don't. Past it, reads fail with
      `"too much work resolving delta bases"` (default unlimited)
    * `:log_label` - when given, such as `"repository alice/notes"`, the first error
      opening or reading a pack is also logged at error level with this label, the
      pack's file name and the reason, never object content (default none). Later
      errors from the same open database aren't logged again.
  """

  require Logger

  alias GitServer.{Object, ObjectId, Pack}
  alias GitServer.Pack.{Cache, Files, Idx, Reader}

  defstruct [:packs, :cache, :files, :names, :log_label, :logged]

  @type t :: %__MODULE__{}

  @defaults [
    max_object_bytes: 50_000_000,
    max_delta_depth: 100,
    cache_bytes: 32_000_000,
    max_open_files: 16,
    max_base_work_bytes: nil,
    log_label: nil,
  ]

  @doc "The default limits."
  def defaults, do: @defaults

  @doc """
  Opens `packs`, a list of `{pack_path, idx_path}`. Each idx is read whole and checked,
  and must match its pack: the same trailer checksum and object count, and offsets
  that are distinct and inside the pack.
  """
  @spec open([{Path.t(), Path.t()}], keyword) :: {:ok, t} | {:error, String.t()}
  def open(packs, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    files = Files.new(opts[:max_open_files])
    cache = Cache.new(opts[:cache_bytes])

    opts =
      Keyword.put(
        opts,
        :base_budget,
        opts[:max_base_work_bytes] &&
          Reader.new_budget(opts[:max_base_work_bytes], "too much work resolving delta bases")
      )

    result =
      packs
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {{pack_path, idx_path}, key}, {:ok, acc} ->
        case open_pack(pack_path, idx_path, key, cache, files, opts) do
          {:ok, pack} ->
            {:cont, {:ok, [pack | acc]}}

          {:error, reason} ->
            log(opts[:log_label], pack_path, reason)
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, acc} ->
        names = Enum.map(packs, fn {pack_path, _idx_path} -> pack_path end)

        {:ok,
         %__MODULE__{
           packs: Enum.reverse(acc),
           cache: cache,
           files: files,
           names: List.to_tuple(names),
           log_label: opts[:log_label],
           logged: :atomics.new(1, []),
         }}

      {:error, reason} ->
        Files.close(files)
        Cache.delete(cache)
        {:error, reason}
    end
  end

  # The pack is opened through the set of open files, which may close it again once
  # later packs are opened; reads reopen it there as they need it.
  defp open_pack(pack_path, idx_path, key, cache, files, opts) do
    with {:ok, idx_binary} <- read_file(idx_path),
         {:ok, idx} <- Idx.decode(idx_binary),
         {:ok, fd} <- open_file(files, key, pack_path),
         {:ok, ends} <- check_pack(fd, idx) do
      reader = %Reader{
        fd: nil,
        key: key,
        ends: ends,
        ref: &Idx.offset(idx, &1),
        cache: cache,
        base_budget: opts[:base_budget],
        max_object_bytes: opts[:max_object_bytes],
        max_delta_depth: opts[:max_delta_depth],
      }

      {:ok, {idx, reader}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, "cannot read pack index: #{:file.format_error(reason)}"}
    end
  end

  defp open_file(files, key, path) do
    case Files.fd(files, key, path) do
      {:ok, fd} -> {:ok, fd}
      {:error, reason} -> {:error, "cannot open pack: #{:file.format_error(reason)}"}
    end
  end

  # The pack's header and trailer must agree with the idx, and every offset must be a
  # distinct position inside the pack. Each object ends where the next one starts.
  defp check_pack(fd, idx) do
    trailer = Pack.trailer_size()

    with {:ok, size} <- file_size(fd),
         true <- size >= Pack.header_size() + trailer,
         {:ok, header} <- :file.pread(fd, 0, Pack.header_size()),
         {:ok, count} when count == idx.count <- Pack.parse_header(header),
         {:ok, checksum} when checksum == idx.pack_checksum <-
           :file.pread(fd, size - trailer, trailer) do
      data_end = size - trailer
      offsets = idx |> Idx.entries() |> Enum.map(&elem(&1, 1)) |> Enum.sort()

      if offsets == Enum.dedup(offsets) and
           Enum.all?(offsets, &(&1 >= Pack.header_size() and &1 < data_end)) do
        ends = Map.new(Enum.zip(offsets, Enum.drop(offsets, 1) ++ [data_end]))
        {:ok, ends}
      else
        {:error, "pack index doesn't match pack"}
      end
    else
      _ -> {:error, "pack index doesn't match pack"}
    end
  end

  defp file_size(fd) do
    case :file.position(fd, :eof) do
      {:ok, size} -> {:ok, size}
      _ -> :error
    end
  end

  @doc "Closes the pack files and drops the cache."
  def close(%__MODULE__{files: files, cache: cache}) do
    Files.close(files)
    Cache.delete(cache)
  end

  @doc """
  The type and size of `id`, `:error` if no pack holds it, or `{:error, reason}` if
  the pack is corrupt or over a limit. A whole object's body isn't inflated; a delta
  is followed to its base for the type.
  """
  @spec lookup(t, ObjectId.t()) ::
          {:ok, Object.type(), non_neg_integer} | :error | {:error, String.t()}
  def lookup(%__MODULE__{} = db, id) do
    with_pack(db, id, fn reader, offset ->
      {type, size} = Reader.type_and_size(reader, offset)
      {:ok, type, size}
    end)
  end

  @doc """
  Reads `id`, deltas resolved. Returns `:error` if no pack holds it, or
  `{:error, reason}` if the pack is corrupt or over a limit.
  """
  @spec read(t, ObjectId.t()) :: {:ok, Object.type(), binary} | :error | {:error, String.t()}
  def read(%__MODULE__{} = db, id) do
    with_pack(db, id, fn reader, offset ->
      {type, content} = Reader.read(reader, offset)
      # A chain step costs its delta's inflating and its result, about twice the
      # object's size when a file's versions are alike.
      Reader.settle(reader.base_budget, 2 * reader.max_delta_depth * byte_size(content))
      {:ok, type, content}
    end)
  end

  @doc "Whether any pack holds `id`."
  def member?(%__MODULE__{packs: packs}, id),
    do: Enum.any?(packs, fn {idx, _} -> Idx.member?(idx, id) end)

  @doc "See `GitServer.Object.parse_links/2`."
  defdelegate parse_links(type, content), to: Object

  defp with_pack(%__MODULE__{packs: packs} = db, id, fun) do
    Enum.find_value(packs, :error, fn {idx, reader} ->
      case Idx.offset(idx, id) do
        {:ok, offset} ->
          with {:error, reason} <- run(fn -> fun.(with_fd(db, reader), offset) end) do
            if :atomics.compare_exchange(db.logged, 1, 0, 1) == :ok,
              do: log(db.log_label, elem(db.names, reader.key), reason)

            {:error, reason}
          end

        :error ->
          nil
      end
    end)
  end

  # A read stays inside one pack (a REF_DELTA base is looked up only in its own idx),
  # so the file it gets here stays open until it returns.
  defp with_fd(db, reader) do
    case open_file(db.files, reader.key, elem(db.names, reader.key)) do
      {:ok, fd} -> %{reader | fd: fd}
      {:error, reason} -> Reader.fail(reason)
    end
  end

  # The reason is one of this module's own messages, which never quote content.
  defp log(nil, _pack_path, _reason), do: :ok

  defp log(label, pack_path, reason) do
    Logger.error("git_server: #{label}: pack #{Path.basename(pack_path)}: #{reason}")
  end

  defp run(fun) do
    fun.()
  catch
    {:pack_error, reason} -> {:error, reason}
    # A stored pack holds every delta base itself.
    {:missing_base, _id} -> {:error, "missing delta base"}
  end
end
