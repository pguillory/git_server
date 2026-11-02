defmodule GitServer.RacingStore do
  @moduledoc """
  A store that delegates to another and runs a function once, just before the first
  conditional write to a key ending in `/state`, so a test can make another push win
  the race at exactly that moment.
  """

  @behaviour GitServer.Store

  def wrap(store, fun) do
    {__MODULE__, %{inner: store, fun: fun, once: :atomics.new(1, [])}}
  end

  @impl true
  def get(config, key), do: GitServer.Store.get(config.inner, key)

  @impl true
  def get_file(config, key, path), do: GitServer.Store.get_file(config.inner, key, path)

  @impl true
  def put(config, key, body, condition) do
    if condition != :none and String.ends_with?(key, "/state") and
         :atomics.compare_exchange(config.once, 1, 0, 1) == :ok,
       do: config.fun.()

    GitServer.Store.put(config.inner, key, body, condition)
  end

  @impl true
  def put_file(config, key, path, condition),
    do: GitServer.Store.put_file(config.inner, key, path, condition)

  @impl true
  def delete(config, key), do: GitServer.Store.delete(config.inner, key)

  @impl true
  def list(config, prefix), do: GitServer.Store.list(config.inner, prefix)

  @impl true
  def describe(config), do: "racing " <> GitServer.Store.describe(config.inner)
end
