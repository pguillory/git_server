defmodule GitServer.OutageStore do
  @moduledoc """
  A store that delegates to another and fails every call of the chosen kinds to keys
  matching a pattern, for testing what a client sees when storage fails.
  `wrap(store, [:get, :get_file], ~r/packs/, "injected outage")` fails pack downloads;
  `wrap(store, [:put], ~r{/state$}, :precondition_failed)` makes every state write
  lose its race.
  """

  @behaviour GitServer.Store

  def wrap(store, calls, pattern, reason) do
    {__MODULE__, %{inner: store, calls: calls, pattern: pattern, reason: reason}}
  end

  @impl true
  def get(config, key), do: call(config, :get, key, &GitServer.Store.get(&1, key))

  @impl true
  def get_file(config, key, path),
    do: call(config, :get_file, key, &GitServer.Store.get_file(&1, key, path))

  @impl true
  def put(config, key, body, condition),
    do: call(config, :put, key, &GitServer.Store.put(&1, key, body, condition))

  @impl true
  def put_file(config, key, path, condition),
    do: call(config, :put_file, key, &GitServer.Store.put_file(&1, key, path, condition))

  @impl true
  def delete(config, key), do: call(config, :delete, key, &GitServer.Store.delete(&1, key))

  @impl true
  def list(config, prefix), do: call(config, :list, prefix, &GitServer.Store.list(&1, prefix))

  @impl true
  def describe(config), do: "outage " <> GitServer.Store.describe(config.inner)

  defp call(config, kind, key, fun) do
    if kind in config.calls and key =~ config.pattern,
      do: {:error, config.reason},
      else: fun.(config.inner)
  end
end
