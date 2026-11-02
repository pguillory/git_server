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
  def types, do: @types

  @doc "The type's name as git writes it."
  def type_name(type) when type in @types, do: Atom.to_string(type)

  @doc "Parses a type name, or returns `:error`."
  def parse_type("commit"), do: {:ok, :commit}
  def parse_type("tree"), do: {:ok, :tree}
  def parse_type("blob"), do: {:ok, :blob}
  def parse_type("tag"), do: {:ok, :tag}
  def parse_type(_), do: :error

  @doc "The header hashed in front of an object's content."
  def header(type, size), do: [type_name(type), ?\s, Integer.to_string(size), 0]

  @doc "An object's id."
  def id(type, content), do: ObjectId.hash([header(type, byte_size(content)), content])

  @doc """
  The objects `content` points to, each with the type it must have.

  A commit points to its tree and its parents (commits). A tree entry's mode decides
  its type: a directory is a tree, a file or symlink a blob, and a gitlink (a
  submodule commit, mode `160000`) is left out because it lives in another
  repository. A tag points to its object with the type the tag declares. A blob points
  to nothing. Returns `{:error, reason}` when the content is malformed.
  """
  @spec parse_links(type, binary) :: {:ok, [link]} | {:error, String.t()}
  def parse_links(:blob, _content), do: {:ok, []}

  def parse_links(:commit, content) do
    with {:ok, tree, rest} <- header_id(content, "tree"),
         {:ok, parents} <- parents(rest, []) do
      {:ok, [{:tree, tree} | Enum.map(parents, &{:commit, &1})]}
    else
      _ -> {:error, "malformed commit"}
    end
  end

  def parse_links(:tag, content) do
    with {:ok, target, rest} <- header_id(content, "object"),
         [type_line, _] <- :binary.split(rest, "\n"),
         "type " <> name <- type_line,
         {:ok, type} <- parse_type(name) do
      {:ok, [{type, target}]}
    else
      _ -> {:error, "malformed tag"}
    end
  end

  def parse_links(:tree, content), do: tree_links(content, [])

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

  defp parents("parent " <> _ = content, acc) do
    case header_id(content, "parent") do
      {:ok, id, rest} -> parents(rest, [id | acc])
      :error -> :error
    end
  end

  defp parents(_content, acc), do: {:ok, Enum.reverse(acc)}

  defp tree_links(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tree_links(content, acc) do
    id_size = ObjectId.size()

    with [mode, rest] <- :binary.split(content, " "),
         {:ok, kind} <- entry_kind(mode),
         [name, <<id::binary-size(id_size), rest::binary>>] when name != "" <-
           :binary.split(rest, <<0>>) do
      case kind do
        :gitlink -> tree_links(rest, acc)
        type -> tree_links(rest, [{type, id} | acc])
      end
    else
      _ -> {:error, "malformed tree"}
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
