defmodule GitServer.Failure do
  @moduledoc false
  # Describes a host callback's failure for the server log without anything the
  # failure carries: no exception message, thrown value, exit reason or call
  # arguments, any of which may quote credentials or pushed content.

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

  defp locations(stacktrace) do
    stacktrace
    |> Enum.map(fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      entry ->
        entry
    end)
    |> Exception.format_stacktrace()
  end
end
