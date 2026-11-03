defmodule GitServer.Object do
  @moduledoc """
  Git objects: their types, ids and the links between them.

  An object's id is the hash of `"<type> <size>\\0"` followed by its content.
  """

  alias GitServer.ObjectId

  @type type :: :commit | :tree | :blob | :tag

  @typedoc """
  A typed referent: what an object points to and the type that target must have.
  """
  @type link :: {type, ObjectId.t()}

  @types [:commit, :tree, :blob, :tag]

  @doc "The four object types."
  def types do
    @types
  end

  @doc "The type's name as git writes it."
  def type_name(type) when type in @types do
    Atom.to_string(type)
  end

  @doc "Parses a type name, or returns `:error`."
  def parse_type("commit") do
    {:ok, :commit}
  end

  def parse_type("tree") do
    {:ok, :tree}
  end

  def parse_type("blob") do
    {:ok, :blob}
  end

  def parse_type("tag") do
    {:ok, :tag}
  end

  def parse_type(_) do
    :error
  end

  @doc "The header hashed in front of an object's content."
  def header(type, size) do
    [type_name(type), ?\s, Integer.to_string(size), 0]
  end

  @doc "An object's id."
  def id(type, content) do
    ObjectId.hash([header(type, byte_size(content)), content])
  end

  @doc """
  The objects `content` points to, each with the type it must have.

  A commit points to its tree and its parents (commits). A tree entry's mode decides
  its type: a directory is a tree, a file or symlink a blob, and a gitlink (a
  submodule commit, mode `160000`) is left out because it lives in another
  repository. A tag points to its object with the type the tag declares. A blob points
  to nothing. Returns `{:error, reason}` when the content is malformed, or when it has
  more than `max` links, which is checked as they're parsed. Each id is copied out of
  `content`, so the links don't keep it alive.
  """
  @spec parse_links(type, binary, non_neg_integer | :infinity) ::
          {:ok, [link]} | {:error, String.t()}
  def parse_links(type, content, max \\ :infinity)

  def parse_links(:blob, _content, _max) do
    {:ok, []}
  end

  def parse_links(:commit, content, max) do
    with {:ok, tree, rest} <- header_id(content, "tree"),
         :ok <- room(1, max),
         {:ok, parents} <- parents(rest, [], 1, max) do
      {:ok, [{:tree, tree} | Enum.map(parents, &{:commit, &1})]}
    else
      :too_many -> {:error, "too many links"}
      _ -> {:error, "malformed commit"}
    end
  end

  def parse_links(:tag, content, max) do
    with {:ok, target, rest} <- header_id(content, "object"),
         :ok <- room(1, max),
         [type_line, _] <- :binary.split(rest, "\n"),
         "type " <> name <- type_line,
         {:ok, type} <- parse_type(name) do
      {:ok, [{type, target}]}
    else
      :too_many -> {:error, "too many links"}
      _ -> {:error, "malformed tag"}
    end
  end

  def parse_links(:tree, content, max) do
    tree_links(content, [], 0, max)
  end

  @doc """
  The bound on a peel's steps from a ref, far more than anyone writes: `GitServer.Push`
  counts tags, a commit and its tree against it, and ls-refs the tags alone.
  """
  def max_peel do
    12
  end

  @doc """
  A tree's entries in order, each `{kind, name, id}`: `kind` is `:tree`, `:file`,
  `:executable`, `:symlink` or `:submodule`, read from the entry's mode the way git
  reads it. Returns `{:error, "malformed tree"}` when the content isn't a tree.
  """
  @spec tree_entries(binary) ::
          {:ok, [{:tree | :file | :executable | :symlink | :submodule, binary, ObjectId.t()}]}
          | {:error, String.t()}
  def tree_entries(content) do
    tree_entries(content, [])
  end

  defp tree_entries(content, acc) do
    case next_entry(content) do
      :done ->
        {:ok, Enum.reverse(acc)}

      {:ok, kind, mode, name, id, rest} ->
        kind =
          case kind do
            :tree -> :tree
            :gitlink -> :submodule
            :blob -> blob_kind(mode)
          end

        tree_entries(rest, [{kind, :binary.copy(name), :binary.copy(id)} | acc])

      :error ->
        {:error, "malformed tree"}
    end
  end

  # A blob entry is a symlink (120000), an executable (the owner's execute bit, which
  # is all git checks out) or a file.
  defp blob_kind(mode) do
    mode = String.to_integer(mode, 8)

    cond do
      Bitwise.band(mode, 0o170000) == 0o120000 -> :symlink
      Bitwise.band(mode, 0o100) != 0 -> :executable
      true -> :file
    end
  end

  # Whether `n` links fit within `max`.
  defp room(n, max) when n <= max do
    :ok
  end

  defp room(_n, _max) do
    :too_many
  end

  defp header_id(content, field) do
    hex_size = ObjectId.size() * 2
    field_size = byte_size(field)

    case content do
      <<^field::binary-size(field_size), ?\s, hex::binary-size(hex_size), ?\n, rest::binary>> ->
        with {:ok, id} <- ObjectId.from_hex(hex), do: {:ok, id, rest}

      _ ->
        :error
    end
  end

  defp parents("parent " <> _ = content, acc, n, max) do
    case header_id(content, "parent") do
      {:ok, _id, _rest} when n >= max -> :too_many
      {:ok, id, rest} -> parents(rest, [id | acc], n + 1, max)
      :error -> :error
    end
  end

  defp parents(_content, acc, _n, _max) do
    {:ok, Enum.reverse(acc)}
  end

  defp tree_links(content, acc, n, max) do
    case next_entry(content) do
      :done ->
        {:ok, Enum.reverse(acc)}

      {:ok, :gitlink, _mode, _name, _id, rest} ->
        tree_links(rest, acc, n, max)

      {:ok, _type, _mode, _name, _id, _rest} when n >= max ->
        {:error, "too many links"}

      {:ok, type, _mode, _name, id, rest} ->
        tree_links(rest, [{type, :binary.copy(id)} | acc], n + 1, max)

      :error ->
        {:error, "malformed tree"}
    end
  end

  # The tree entry at the start of `content`: `{:ok, kind, mode, name, id, rest}`, with
  # `kind` from `entry_kind/1` and `name` and `id` still sub-binaries of `content`,
  # `:done` at the end, or `:error`.
  defp next_entry(<<>>) do
    :done
  end

  defp next_entry(content) do
    id_size = ObjectId.size()

    with [mode, rest] <- :binary.split(content, " "),
         {:ok, kind} <- entry_kind(mode),
         [name, <<id::binary-size(id_size), rest::binary>>] when name != "" <-
           :binary.split(rest, <<0>>) do
      {:ok, kind, mode, name, id, rest}
    else
      _ -> :error
    end
  end

  # The file type bits of a tree entry's octal mode, the way git reads them.
  defp entry_kind(mode) do
    if mode != "" and byte_size(mode) <= 7 and String.match?(mode, ~r/\A[0-7]+\z/) do
      case Bitwise.band(String.to_integer(mode, 8), 0o170000) do
        0o040000 -> {:ok, :tree}
        0o100000 -> {:ok, :blob}
        0o120000 -> {:ok, :blob}
        0o160000 -> {:ok, :gitlink}
        _ -> :error
      end
    else
      :error
    end
  end
end
