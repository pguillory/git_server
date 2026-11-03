defmodule GitServer.Pack.Reader do
  @moduledoc """
  Reads objects out of one pack file whose object boundaries are known, resolving
  deltas.

  `ends` maps each object's offset to the offset just past it. A REF_DELTA base is
  found with `ref`, a function from an id to `{:ok, offset}` or `:error`. A delta
  chain is walked iteratively down to a whole object (or a cached one) and then
  applied back up, so the working set is one base and one result plus the cache.

  `budget` is charged for all the work of a read, and `base_budget` only for the
  work of resolving the bases under the object read: inflating them and applying
  their deltas, which the cache would have saved. Either may be nil.

  Errors are thrown as `{:pack_error, reason}`, and a REF_DELTA base that `ref` can't
  find as `{:missing_base, id}`; callers turn them into `{:error, reason}`.
  """

  alias GitServer.Pack
  alias GitServer.Pack.{Cache, Delta}

  @chunk 65_536
  @max_header 40

  @enforce_keys [:fd, :ends, :ref, :cache, :max_object_bytes, :max_delta_depth]
  defstruct [:key, :budget, :base_budget | @enforce_keys]

  @doc false
  # A budget of bytes inflated and produced by deltas, shared by everything that
  # charges it, failing with `message` once spent. `nil` means unlimited.
  def new_budget(max, message \\ "pack needs too much work to index"),
    do: {:counters.new(1, []), max, message}

  @doc false
  def charge(nil, _bytes), do: :ok

  def charge({ref, max, message}, bytes) do
    :counters.add(ref, 1, bytes)
    if :counters.get(ref, 1) > max, do: fail(message)
    :ok
  end

  @doc "Parses the entry header at `offset`."
  def entry(%__MODULE__{} = r, offset) do
    stop = Map.get(r.ends, offset) || fail("bad delta base offset")
    bin = pread(r.fd, offset, min(stop - offset, @max_header))

    case Pack.parse_object_header(bin, offset) do
      {:ok, _kind, size, _used} when size > r.max_object_bytes ->
        fail("object too large")

      {:ok, kind, size, used} when offset + used <= stop ->
        %{offset: offset, kind: kind, size: size, start: offset + used, stop: stop}

      {:error, reason} ->
        fail(reason)

      _ ->
        fail("truncated object")
    end
  end

  @doc "Reads the object at `offset`, returning `{type, content}`."
  def read(%__MODULE__{} = r, offset), do: walk(r, offset, [], 0)

  @doc "The type and size of the object at `offset`, without inflating a whole object."
  def type_and_size(%__MODULE__{} = r, offset) do
    e = entry(r, offset)

    case e.kind do
      {:base, type} ->
        {type, e.size}

      _delta ->
        case Delta.sizes(inflate_prefix(r, e, 20)) do
          {:ok, _base_size, size, _} when size <= r.max_object_bytes -> {base_type(r, e, 0), size}
          {:ok, _, _, _} -> fail("object too large")
          {:error, reason} -> fail(reason)
        end
    end
  end

  # The cache holds each resolved object with its own chain depth, so a chain that
  # stops at a cached object still counts its full depth.
  defp walk(r, offset, deltas, depth) do
    case Cache.get(r.cache, {r.key, offset}) do
      {:ok, {type, content, base_depth}} ->
        if base_depth + depth > r.max_delta_depth, do: fail("delta chain too deep")
        apply_chain(r, type, content, base_depth, deltas)

      :error ->
        e = entry(r, offset)

        case e.kind do
          {:base, type} ->
            content = inflate(r, e)

            if deltas != [] do
              charge(r.base_budget, inflate_work(e))
              Cache.put(r.cache, {r.key, offset}, {type, content, 0}, e.size)
            end

            apply_chain(r, type, content, 0, deltas)

          _delta ->
            walk(r, base_offset(r, e, depth), [e | deltas], depth + 1)
        end
    end
  end

  defp base_type(r, e, depth) do
    case e.kind do
      {:base, type} -> type
      _delta -> base_type(r, entry(r, base_offset(r, e, depth)), depth + 1)
    end
  end

  # Counting depth also stops a cycle of REF_DELTAs.
  defp base_offset(r, _e, depth) when depth >= r.max_delta_depth, do: fail("delta chain too deep")
  defp base_offset(_r, %{kind: {:ofs, base}}, _depth), do: base

  defp base_offset(r, %{kind: {:ref, id}}, _depth) do
    case r.ref.(id) do
      {:ok, base} -> base
      :error -> throw({:missing_base, id})
    end
  end

  # `deltas` runs from the one nearest the base to the object read, the last.
  defp apply_chain(r, type, content, depth, deltas) do
    last = length(deltas) - 1

    {type, content, _depth} =
      deltas
      |> Enum.with_index()
      |> Enum.reduce({type, content, depth}, fn {e, n}, {type, base, depth} ->
        case Delta.apply(base, inflate(r, e), r.max_object_bytes) do
          {:ok, result} ->
            charge(r.budget, byte_size(result))
            if n < last, do: charge(r.base_budget, inflate_work(e) + byte_size(result))
            Cache.put(r.cache, {r.key, e.offset}, {type, result, depth + 1}, byte_size(result))
            {type, result, depth + 1}

          {:error, reason} ->
            fail(reason)
        end
      end)

    {type, content}
  end

  @doc """
  Inflates an entry's zlib stream, which must end by the entry's end and give exactly
  its declared size.
  """
  def inflate(%__MODULE__{} = r, e) do
    charge(r.budget, inflate_work(e))

    with_inflater(fn z ->
      out = inflate_range(r.fd, z, e.start, e.stop, e.size, 0, [])
      :zlib.inflateEnd(z)
      out
    end)
  end

  # zlib's work follows its input as well as its output (empty stored blocks).
  defp inflate_work(e), do: max(e.size, e.stop - e.start)

  defp inflate_range(_fd, _z, pos, stop, size, size, acc) when pos >= stop,
    do: IO.iodata_to_binary(Enum.reverse(acc))

  defp inflate_range(_fd, _z, pos, stop, _size, _n, _acc) when pos >= stop,
    do: fail("object size mismatch")

  defp inflate_range(fd, z, pos, stop, size, n, acc) do
    chunk = pread(fd, pos, min(@chunk, stop - pos))
    {n, acc} = drain(z, safe_inflate(z, chunk), size, n, acc)
    inflate_range(fd, z, pos + byte_size(chunk), stop, size, n, acc)
  end

  defp drain(z, {status, out}, size, n, acc) do
    n = n + IO.iodata_length(out)
    if n > size, do: fail("object size mismatch")
    acc = [out | acc]
    if status == :continue, do: drain(z, safe_inflate(z, []), size, n, acc), else: {n, acc}
  end

  # At least the first `want` bytes of an entry's content, or all of it if shorter.
  defp inflate_prefix(r, e, want) do
    with_inflater(fn z -> prefix(r.fd, z, e.start, e.stop, want, <<>>) end)
  end

  defp prefix(_fd, _z, pos, stop, want, have) when byte_size(have) >= want or pos >= stop,
    do: have

  defp prefix(fd, z, pos, stop, want, have) do
    chunk = pread(fd, pos, min(@chunk, stop - pos))
    have = prefix_drain(z, safe_inflate(z, chunk), want, have)
    prefix(fd, z, pos + byte_size(chunk), stop, want, have)
  end

  defp prefix_drain(z, {status, out}, want, have) do
    have = have <> IO.iodata_to_binary(out)

    if status == :continue and byte_size(have) < want,
      do: prefix_drain(z, safe_inflate(z, []), want, have),
      else: have
  end

  @doc false
  def with_inflater(fun) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z)
      fun.(z)
    rescue
      e in ErlangError ->
        if match?(%ErlangError{original: :data_error}, e),
          do: fail("corrupt object"),
          else: reraise(e, __STACKTRACE__)
    after
      :zlib.close(z)
    end
  end

  @doc false
  # Pack streams never use a preset dictionary; one that asks for it is corrupt.
  def safe_inflate(z, data) do
    case :zlib.safeInflate(z, data) do
      {:need_dictionary, _adler, _out} -> fail("corrupt object")
      result -> result
    end
  end

  @doc false
  def pread(fd, pos, len) do
    case :file.pread(fd, pos, len) do
      {:ok, bin} when byte_size(bin) == len -> bin
      {:ok, _short} -> fail("truncated pack")
      :eof -> fail("truncated pack")
      {:error, reason} -> fail("pack read failed: #{inspect(reason)}")
    end
  end

  @doc false
  def fail(reason), do: throw({:pack_error, reason})
end
