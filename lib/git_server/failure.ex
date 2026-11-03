defmodule GitServer.Failure do
  @moduledoc false
  # Describes a host callback's failure, or a store call's in a task, for the server
  # log without anything the failure carries: no exception message, thrown value,
  # exit reason or call arguments, any of which may quote credentials or pushed
  # content.

  @doc """
  The kind of a caught failure, an exception's module, and the stacktrace without
  arguments, for example "raised FunctionClauseError" and its locations.
  """
  def describe(:error, reason, stacktrace) do
    exception = Exception.normalize(:error, reason, stacktrace)
    "raised #{inspect(exception.__struct__)}\n" <> locations(stacktrace)
  end

  def describe(:throw, _value, stacktrace), do: "threw\n" <> locations(stacktrace)
  def describe(:exit, _reason, stacktrace), do: "exited\n" <> locations(stacktrace)

  @doc """
  Runs `fun`, turning a raise, throw or exit into `{:error, "<what> <description>"}`,
  for work run in a linked task, where a failure would otherwise exit the caller.
  """
  def catching(what, fun) do
    fun.()
  catch
    kind, reason -> {:error, "#{what} " <> describe(kind, reason, __STACKTRACE__)}
  end

  defp locations(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      {fun, args, location} when is_list(args) ->
        {fun, length(args), location}

      entry ->
        entry
    end)
    |> Exception.format_stacktrace()
  end
end
