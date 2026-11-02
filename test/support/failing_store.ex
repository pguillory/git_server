defmodule GitServer.FailingStore do
  @moduledoc """
  A store that delegates to another and fails chosen writes, for testing what a
  failed write leaves behind. `wrap(store, suffix, count)` fails the next `count`
  puts to keys ending in `suffix`, with `{:error, "injected failure"}`.
  """

  @behaviour GitServer.Store

  def wrap(store, suffix, count) do
    counter = :atomics.new(1, signed: true)
    :atomics.put(counter, 1, count)
    {__MODULE__, %{inner: store, suffix: suffix, counter: counter}}
  end

  @impl true
  def get(config, key), do: GitServer.Store.get(config.inner, key)

  @impl true
  def get_file(config, key, path), do: GitServer.Store.get_file(config.inner, key, path)

  @impl true
  def put(config, key, body, condition) do
    with :ok <- maybe_fail(config, key),
         do: GitServer.Store.put(config.inner, key, body, condition)
  end

  @impl true
  def put_file(config, key, path, condition) do
    with :ok <- maybe_fail(config, key),
         do: GitServer.Store.put_file(config.inner, key, path, condition)
  end

  @impl true
  def delete(config, key), do: GitServer.Store.delete(config.inner, key)

  @impl true
  def list(config, prefix), do: GitServer.Store.list(config.inner, prefix)

  @impl true
  def describe(config), do: "failing " <> GitServer.Store.describe(config.inner)

  defp maybe_fail(config, key) do
    if String.ends_with?(key, config.suffix) and :atomics.sub_get(config.counter, 1, 1) >= 0,
      do: {:error, "injected failure"},
      else: :ok
  end
end
