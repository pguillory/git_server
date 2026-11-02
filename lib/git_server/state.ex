defmodule GitServer.State do
  @moduledoc """
  A repository's `state` object: HEAD, the refs and the list of packs, as plain
  text:

      git_server state 1
      head refs/heads/main
      pack <40 hex>
      ref <40 hex> refs/heads/main

  Pack lines are in push order (oldest first), ref lines sorted by name. HEAD is
  always a symref. Object ids and pack names are lowercase hex strings here and on
  the wire. A missing `state` object is an empty repository, `new/0`.
  """

  @header "git_server state 1"
  @default_head "refs/heads/main"

  defstruct head: @default_head, packs: [], refs: %{}

  @type t :: %__MODULE__{
          head: String.t(),
          packs: [String.t()],
          refs: %{String.t() => String.t()},
        }

  @doc "The state of an empty repository: HEAD on `refs/heads/main`, nothing else."
  def new do
    %__MODULE__{}
  end

  @doc "Encodes a state as text."
  def encode(%__MODULE__{} = state) do
    lines =
      [@header, "head #{state.head}"] ++
        Enum.map(state.packs, &"pack #{&1}") ++
        (state.refs |> Enum.sort() |> Enum.map(fn {name, id} -> "ref #{id} #{name}" end))

    Enum.map_join(lines, &(&1 <> "\n"))
  end

  @doc "Decodes a state: `{:ok, state}` or `{:error, reason}`."
  def decode(text) do
    case String.split(text, "\n") do
      [@header | lines] -> decode_lines(lines, %{head: nil, packs: [], refs: []})
      _ -> {:error, "not a git_server state object"}
    end
  end

  defp decode_lines([""], acc) do
    finish(acc)
  end

  defp decode_lines([], _acc) do
    {:error, "state is truncated"}
  end

  defp decode_lines([_unterminated], _acc) do
    {:error, "state is truncated"}
  end

  defp decode_lines(["head " <> head | lines], %{head: nil} = acc) do
    if valid_name?(head), do: decode_lines(lines, %{acc | head: head}), else: malformed()
  end

  defp decode_lines(["pack " <> name | lines], acc) do
    if id?(name), do: decode_lines(lines, %{acc | packs: [name | acc.packs]}), else: malformed()
  end

  defp decode_lines(["ref " <> <<id::binary-size(40), " ", name::binary>> | lines], acc) do
    if id?(id) and valid_name?(name),
      do: decode_lines(lines, %{acc | refs: [{name, id} | acc.refs]}),
      else: malformed()
  end

  defp decode_lines([_line | _], _acc) do
    malformed()
  end

  defp finish(%{head: nil}) do
    {:error, "state has no head"}
  end

  defp finish(acc) do
    refs = Enum.reverse(acc.refs)
    names = Enum.map(refs, &elem(&1, 0))
    packs = Enum.reverse(acc.packs)

    cond do
      names != Enum.sort(names) or names != Enum.uniq(names) ->
        {:error, "state refs are not sorted and unique"}

      packs != Enum.uniq(packs) ->
        {:error, "state lists a pack twice"}

      true ->
        {:ok, %__MODULE__{head: acc.head, packs: packs, refs: Map.new(refs)}}
    end
  end

  # The state's text is a store response body, so it stays out of the error.
  defp malformed do
    {:error, "malformed state"}
  end

  defp id?(text) do
    text =~ ~r/\A[0-9a-f]{40}\z/
  end

  # Ref names are checked fully when a push creates them; here only that they fit a line.
  defp valid_name?(name) do
    name != "" and not String.match?(name, ~r/[\x00-\x20\x7f]/)
  end
end
