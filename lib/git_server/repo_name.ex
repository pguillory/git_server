defmodule GitServer.RepoName do
  @moduledoc """
  Repository names, taken from the request path. A name is one or more
  `/`-separated segments of `[A-Za-z0-9._-]`, at most 200 bytes in all. No segment
  is empty or starts with `.` (so none is `.` or `..`), and once one trailing `.git`
  is stripped from the last segment, no segment ends in `.git`. So `alice/notes` and
  `alice/notes.git` are the same repository, and `notes.git.git` is refused.

  The raw path is checked, never decoded: percent-encoded bytes, NUL and
  backslashes are refused. The name is canonicalized once, before authorization,
  and that one value names the repository everywhere. Its objects live under
  `<name>.git/` in the store. Every repository folder ends in `.git/` and no name
  segment does, so no two repositories' keys can overlap.
  """

  @max_bytes 200

  @doc """
  The canonical name for the raw path segments before the service part of the URL
  (`info/refs`, `git-upload-pack`, `git-receive-pack`), given the raw request path
  too, since Plug drops empty segments: `{:ok, name}` or `:error`.
  """
  def parse(request_path, segments) do
    if String.contains?(request_path, ["//", "%", "\\", <<0>>]) do
      :error
    else
      parse_segments(segments)
    end
  end

  defp parse_segments([_ | _] = segments) do
    {init, [last]} = Enum.split(segments, -1)
    segments = init ++ [String.replace_suffix(last, ".git", "")]
    name = Enum.join(segments, "/")

    if byte_size(name) <= @max_bytes and Enum.all?(segments, &valid_segment?/1) do
      {:ok, name}
    else
      :error
    end
  end

  defp parse_segments(_segments) do
    :error
  end

  defp valid_segment?(segment) do
    segment =~ ~r/\A[A-Za-z0-9._-]+\z/ and not String.starts_with?(segment, ".") and
      not String.ends_with?(segment, ".git")
  end

  @doc "The store key prefix for a repository's objects."
  def key_prefix(name) do
    name <> ".git/"
  end
end
