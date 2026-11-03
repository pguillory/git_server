defmodule GitServer.StyleTest do
  # The conventions in AGENTS.md that a scan can check, over every Elixir file in the
  # repository.
  use ExUnit.Case, async: true

  @defs [:def, :defp, :defmacro, :defmacrop]

  defp sources do
    root = Path.expand("../..", __DIR__)

    for pattern <- ["*.{ex,exs}", "{lib,test,dev}/**/*.{ex,exs}"],
        path <- Path.wildcard(Path.join(root, pattern)) do
      {Path.relative_to(path, root),
       Code.string_to_quoted!(File.read!(path), token_metadata: true)}
    end
  end

  # `{file, line}` of every node `pred` picks out.
  defp find(pred) do
    for {file, ast} <- sources(),
        {_, lines} = Macro.prewalk(ast, [], &collect(&1, &2, pred)),
        line <- Enum.reverse(lines),
        do: {file, line}
  end

  defp collect({_, meta, _} = node, acc, pred) do
    if pred.(node), do: {node, [meta[:line] | acc]}, else: {node, acc}
  end

  defp collect(node, acc, _pred) do
    {node, acc}
  end

  test "every def is written with do...end" do
    keyword_defs =
      find(fn
        {name, meta, [_head, [{:do, _} | _]]} when name in @defs ->
          not Keyword.has_key?(meta, :do)

        _ ->
          false
      end)

    assert keyword_defs == []
  end

  test "one alias per line" do
    multi_aliases =
      find(fn
        {:alias, _, [{{:., _, [_, :{}]}, _, _} | _]} -> true
        _ -> false
      end)

    assert multi_aliases == []
  end
end
