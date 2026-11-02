defmodule GitServer.ObjectDB do
  @moduledoc """
  Reads objects from a set of local pack files, each with its idx.

  Open it in the process that will use it: it holds that process's file handles and a
  private cache of resolved delta bases, and both go away with the process or with
  `close/1`. Nothing here raises on a hostile or corrupt pack; errors come back as
  `{:error, reason}` with a human-readable reason.

  Options, for `open/2`:

    * `:max_object_bytes` - the largest object (or delta) to inflate (default 50 MB)
    * `:max_delta_depth` - the longest delta chain to follow (default 100)
    * `:cache_bytes` - the size of the resolved-base cache (default 32 MB)
  """

  alias GitServer.{Object, ObjectId, Pack}
  alias GitServer.Pack.{Cache, Idx, Reader}

  defstruct [:packs, :cache]

  @type t :: %__MODULE__{}

  @defaults [max_object_bytes: 50_000_000, max_delta_depth: 100, cache_bytes: 32_000_000]

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
    cache = Cache.new(opts[:cache_bytes])

    result =
      packs
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {{pack_path, idx_path}, key}, {:ok, acc} ->
        case open_pack(pack_path, idx_path, key, cache, opts) do
          {:ok, pack} -> {:cont, {:ok, [pack | acc]}}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      end)

    case result do
      {:ok, acc} ->
        {:ok, %__MODULE__{packs: Enum.reverse(acc), cache: cache}}

      {:error, reason, acc} ->
        Enum.each(acc, fn {_idx, reader} -> File.close(reader.fd) end)
        Cache.delete(cache)
        {:error, reason}
    end
  end

  defp open_pack(pack_path, idx_path, key, cache, opts) do
    with {:ok, idx_binary} <- read_file(idx_path),
         {:ok, idx} <- Idx.decode(idx_binary),
         {:ok, fd} <- open_file(pack_path) do
      case check_pack(fd, idx) do
        {:ok, ends} ->
          reader = %Reader{
            fd: fd,
            key: key,
            ends: ends,
            ref: &Idx.offset(idx, &1),
            cache: cache,
            max_object_bytes: opts[:max_object_bytes],
            max_delta_depth: opts[:max_delta_depth],
          }

          {:ok, {idx, reader}}

        {:error, reason} ->
          File.close(fd)
          {:error, reason}
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, "cannot read pack index: #{:file.format_error(reason)}"}
    end
  end

  defp open_file(path) do
    case :file.open(path, [:read, :raw, :binary]) do
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
  def close(%__MODULE__{packs: packs, cache: cache}) do
    Enum.each(packs, fn {_idx, reader} -> File.close(reader.fd) end)
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
      {:ok, type, content}
    end)
  end

  @doc "Whether any pack holds `id`."
  def member?(%__MODULE__{packs: packs}, id),
    do: Enum.any?(packs, fn {idx, _} -> Idx.member?(idx, id) end)

  @doc "See `GitServer.Object.parse_links/2`."
  defdelegate parse_links(type, content), to: Object

  defp with_pack(%__MODULE__{packs: packs}, id, fun) do
    Enum.find_value(packs, :error, fn {idx, reader} ->
      case Idx.offset(idx, id) do
        {:ok, offset} -> run(fn -> fun.(reader, offset) end)
        :error -> nil
      end
    end)
  end

  defp run(fun) do
    fun.()
  catch
    {:pack_error, reason} -> {:error, reason}
    # A stored pack holds every delta base itself.
    {:missing_base, _id} -> {:error, "missing delta base"}
  end
end
