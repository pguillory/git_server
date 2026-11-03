defmodule GitServer.CountingStore do
  @moduledoc """
  A store that delegates to another and counts its reads: `get` and `get_file` calls.
  """
  @behaviour GitServer.Store
  alias GitServer.Store

  def wrap(store), do: {__MODULE__, %{inner: store, counts: :counters.new(2, [])}}

  @doc "The reads so far: `%{gets: n, get_files: n}`."
  def counts({__MODULE__, %{counts: counts}}),
    do: %{gets: :counters.get(counts, 1), get_files: :counters.get(counts, 2)}

  @doc "Sets the counts back to zero."
  def reset({__MODULE__, %{counts: counts}}) do
    :counters.put(counts, 1, 0)
    :counters.put(counts, 2, 0)
  end

  @impl true
  def get(config, key) do
    :counters.add(config.counts, 1, 1)
    Store.get(config.inner, key)
  end

  @impl true
  def get_file(config, key, path) do
    :counters.add(config.counts, 2, 1)
    Store.get_file(config.inner, key, path)
  end

  @impl true
  def put(config, key, body, condition), do: Store.put(config.inner, key, body, condition)

  @impl true
  def put_file(config, key, path, condition),
    do: Store.put_file(config.inner, key, path, condition)

  @impl true
  def delete(config, key), do: Store.delete(config.inner, key)

  @impl true
  def list(config, prefix), do: Store.list(config.inner, prefix)

  @impl true
  def describe(config), do: Store.describe(config.inner)
end
