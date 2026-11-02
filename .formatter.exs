# Used by "mix format"
defmodule GitServer.Formatter do
  @behaviour Mix.Tasks.Format
  # Mix loads formatter dependencies after evaluating this configuration.
  @compile {:no_warn_undefined, FreedomFormatter}

  defdelegate features(opts), to: FreedomFormatter

  def format(content, opts) do
    # Newly wrapped literals need a second pass for commas:
    # https://github.com/marcandre/freedom_formatter/issues/9
    content
    |> FreedomFormatter.format(opts)
    |> FreedomFormatter.format(opts)
  end
end

[
  plugins: [GitServer.Formatter],
  trailing_comma: true,
  inputs: ["*.{ex,exs}", "{config,lib,test,dev}/**/*.{ex,exs}"],
]
