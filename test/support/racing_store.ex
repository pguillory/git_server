defmodule GitServer.RacingStore do
  @moduledoc """
  A store that delegates to another and runs a function once, just before the first
  conditional write to a key ending in `/state`, so a test can make another push (or
  a compaction) win the race at exactly that moment.
  """

  @behaviour GitServer.Store

  def wrap(store, fun) do
    {__MODULE__, %{inner: store, fun: fun, once: :atomics.new(1, []), read: nil}}
  end

  @doc """
  Instead runs `fun` once, just after the `n`th read of a key ending in `/state`, so a
  test can change the repository between a request's state read and what it does next.
  """
  def after_read(store, n, fun) do
    {__MODULE__,
     %{inner: store, fun: fun, once: :atomics.new(1, []), read: {n, :atomics.new(1, [])}}}
  end

  @impl true
  def get(%{read: {n, reads}} = config, key) do
    result = GitServer.Store.get(config.inner, key)

    if String.ends_with?(key, "/state") and :atomics.add_get(reads, 1, 1) == n,
      do: config.fun.()

    result
  end

  def get(config, key) do
    GitServer.Store.get(config.inner, key)
  end

  @impl true
  def get_file(config, key, path) do
    GitServer.Store.get_file(config.inner, key, path)
  end

  @impl true
  def put(config, key, body, condition) do
    if config.read == nil and condition != :none and String.ends_with?(key, "/state") and
         :atomics.compare_exchange(config.once, 1, 0, 1) == :ok,
       do: config.fun.()

    GitServer.Store.put(config.inner, key, body, condition)
  end

  @impl true
  def put_file(config, key, path, condition) do
    GitServer.Store.put_file(config.inner, key, path, condition)
  end

  @impl true
  def delete(config, key) do
    GitServer.Store.delete(config.inner, key)
  end

  @impl true
  def list(config, prefix) do
    GitServer.Store.list(config.inner, prefix)
  end

  @impl true
  def describe(config) do
    "racing " <> GitServer.Store.describe(config.inner)
  end
end
