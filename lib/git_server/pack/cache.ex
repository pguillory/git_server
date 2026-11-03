defmodule GitServer.Pack.Cache do
  @moduledoc """
  A byte-bounded cache of resolved objects, used while resolving delta chains.

  It lives in a private ETS table owned by the calling process, so it disappears
  with that process. Entries are evicted oldest first once the total size of their
  binaries passes the limit. An object bigger than the limit isn't cached.
  """

  defstruct [:table, :order, :max_bytes]

  @type t :: %__MODULE__{}

  @doc "Creates a cache holding at most `max_bytes` of object content, counting a fixed overhead per entry."
  def new(max_bytes) do
    table = :ets.new(__MODULE__, [:set, :private])
    order = :ets.new(__MODULE__, [:ordered_set, :private])
    :ets.insert(table, [{:bytes, 0}, {:seq, 0}])
    %__MODULE__{table: table, order: order, max_bytes: max_bytes}
  end

  @doc "Deletes the cache's tables."
  def delete(%__MODULE__{table: table, order: order}) do
    :ets.delete(table)
    :ets.delete(order)
    :ok
  end

  @doc "Looks up `key`."
  def get(%__MODULE__{table: table}, key) do
    case :ets.lookup(table, {:entry, key}) do
      [{_, value, _size}] -> {:ok, value}
      [] -> :error
    end
  end

  # Each entry is charged its bookkeeping too, so even empty objects use up the limit.
  @overhead 128

  @doc "Stores `value`, whose content is `size` bytes, under `key`."
  def put(%__MODULE__{max_bytes: max}, _key, _value, size) when size + @overhead > max do
    :ok
  end

  def put(%__MODULE__{table: table, order: order} = cache, key, value, size) do
    size = size + @overhead

    if :ets.insert_new(table, {{:entry, key}, value, size}) do
      seq = :ets.update_counter(table, :seq, 1)
      :ets.insert(order, {seq, key})
      bytes = :ets.update_counter(table, :bytes, size)
      evict(cache, bytes)
    end

    :ok
  end

  defp evict(%__MODULE__{max_bytes: max}, bytes) when bytes <= max do
    :ok
  end

  defp evict(%__MODULE__{table: table, order: order} = cache, _bytes) do
    seq = :ets.first(order)
    [{^seq, key}] = :ets.lookup(order, seq)
    [{_, _value, size}] = :ets.lookup(table, {:entry, key})
    :ets.delete(order, seq)
    :ets.delete(table, {:entry, key})
    evict(cache, :ets.update_counter(table, :bytes, -size))
  end
end
