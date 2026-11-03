defmodule GitServer.Push do
  @moduledoc """
  A push, as the host's `:before_update` function sees it before anything is
  published (see "Checking a push" in `GitServer.ReceivePack`).

  - `repo`: the repository name.
  - `conn`: the request's `Plug.Conn`, with its Authorization header already
    dropped. Read it (for example its assigns); don't send on it.
  - `refs`: the repository's refs now, before this push: `%{name => hex_id}`.
  - `updates`: the ref updates that land if the function approves, in the client's
    order: `[%{ref: name, old: hex_id | nil, new: hex_id | nil}]`, where `nil` means
    absent, so `old: nil` creates a ref and `new: nil` deletes it. Only updates that
    passed the server's own checks are listed.

  `list_files/3` and `read_file/3` read the tree at any commit in the repository or
  the pushed pack, so both a ref's old and new tip can be read. They work only during
  the call, and only in the process the function was called in.
  """

  alias GitServer.{Object, ObjectDB, ObjectId}

  @enforce_keys [:repo, :conn, :refs, :updates, :db]
  defstruct @enforce_keys

  @type update :: %{ref: String.t(), old: String.t() | nil, new: String.t() | nil}
  @type t :: %__MODULE__{
          repo: String.t(),
          conn: Plug.Conn.t(),
          refs: %{String.t() => String.t()},
          updates: [update],
        }
  @type file_type :: :file | :executable | :symlink | :submodule

  defimpl Inspect do
    def inspect(push, opts) do
      fields = [repo: push.repo, refs: push.refs, updates: push.updates]
      Inspect.Algebra.concat(["#GitServer.Push<", Inspect.List.inspect(fields, opts), ">"])
    end
  end

  @doc """
  Every file under the tree at `id` (a commit, an annotated tag of one, or a tree,
  in hex), recursively, sorted by path: `{:ok, [%{path: path, type: type, id:
  hex_id}]}` with `type` one of `:file`, `:executable`, `:symlink` and `:submodule`.
  Directories aren't listed.

  Returns `{:error, reason}` when `id` isn't there or isn't a commit, tag or tree,
  when an object can't be read, when a tree has an entry name git wouldn't check out
  (see `read_file/3`), or past either budget: `:max_entries` entries visited,
  directories included (default 100,000), or `:max_path_bytes` bytes of paths
  built, directories included (default 10 MB). Trees can share subtrees, so a few
  pushed objects could otherwise stand for millions of paths.
  """
  @spec list_files(t, String.t(), keyword) ::
          {:ok, [%{path: String.t(), type: file_type, id: String.t()}]} | {:error, String.t()}
  def list_files(%__MODULE__{db: db}, id, opts \\ []) do
    budget =
      {Keyword.get(opts, :max_entries, 100_000), Keyword.get(opts, :max_path_bytes, 10_000_000)}

    with {:ok, tree} <- root_tree(db, id),
         {:ok, files, _budget} <- walk(db, tree, "", [], budget) do
      {:ok, Enum.sort_by(files, & &1.path)}
    end
  end

  # Depth first. Every entry, and every byte of every path, is charged before the
  # path is built.
  defp walk(db, tree, prefix, acc, budget) do
    with {:ok, entries} <- read_tree(db, tree) do
      Enum.reduce_while(entries, {:ok, acc, budget}, fn {kind, name, id}, {:ok, acc, budget} ->
        case charge(budget, byte_size(prefix) + byte_size(name)) do
          {:error, reason} ->
            {:halt, {:error, reason}}

          {:ok, budget} when kind == :tree ->
            case walk(db, id, prefix <> name <> "/", acc, budget) do
              {:ok, acc, budget} -> {:cont, {:ok, acc, budget}}
              error -> {:halt, error}
            end

          {:ok, budget} ->
            file = %{path: prefix <> name, type: kind, id: hex(id)}
            {:cont, {:ok, [file | acc], budget}}
        end
      end)
    end
  end

  defp charge({entries, _bytes}, _size) when entries < 1, do: {:error, "too many files"}
  defp charge({_entries, bytes}, size) when size + 1 > bytes, do: {:error, "paths too long"}
  # The extra byte is the path's `/` or its entry's own overhead, so even empty names
  # use up the budget.
  defp charge({entries, bytes}, size), do: {:ok, {entries - 1, bytes - size - 1}}

  @doc """
  The content of the file at `path` (`/`-separated, no leading slash) in the tree at
  `id`: `{:ok, binary}` for a file or an executable. Returns `:error` when there's
  no such file there (missing, a directory or a submodule) or `path` has an empty,
  `.` or `..` part.

  Returns `{:error, reason}` when `id` isn't a commit, tag or tree, when an object
  can't be read (for example over `:max_object_bytes`), when the path is or passes
  through a symlink (symlinks aren't followed, so one can't pass for a file or hide
  one), or when a tree on the way has an unsafe entry name: `.`, `..`, `.git` or a
  name a case-insensitive file system would take for it (`.GIT`, `.git.`, `git~1`),
  one holding a `/`, or two names that differ only in case. So a path that reads
  without error is the file a clone would have there, short of rarer file-system
  aliases this doesn't check.
  """
  @spec read_file(t, String.t(), String.t()) :: {:ok, binary} | :error | {:error, String.t()}
  def read_file(%__MODULE__{db: db}, id, path) do
    names = String.split(path, "/")

    if Enum.any?(names, &(&1 in ["", ".", ".."])) do
      :error
    else
      with {:ok, tree} <- root_tree(db, id), do: find(db, tree, names)
    end
  end

  defp find(db, tree, [name | rest]) do
    with {:ok, entries} <- read_tree(db, tree) do
      case {List.keyfind(entries, name, 1), rest} do
        {{:tree, ^name, id}, [_ | _]} -> find(db, id, rest)
        {{kind, ^name, id}, []} when kind in [:file, :executable] -> read_blob(db, id)
        {{:symlink, ^name, _id}, _rest} -> {:error, "#{name} is a symlink"}
        _ -> :error
      end
    end
  end

  defp read_blob(db, id) do
    case ObjectDB.read(db, id) do
      {:ok, :blob, content} -> {:ok, content}
      {:ok, type, _} -> {:error, "#{hex(id)} is a #{type}, not a blob"}
      :error -> {:error, "missing blob #{hex(id)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_tree(db, id) do
    case ObjectDB.read(db, id) do
      {:ok, :tree, content} ->
        with {:ok, entries} <- Object.tree_entries(content), do: check_names(entries, id)

      {:ok, type, _} ->
        {:error, "#{hex(id)} is a #{type}, not a tree"}

      :error ->
        {:error, "missing tree #{hex(id)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Names a checkout could write somewhere other than where the path says, on any
  # file system git supports. Not every alias git's own fsck knows (such as ignorable
  # Unicode in HFS+), but the common ones.
  defp check_names(entries, id) do
    folded = Enum.map(entries, fn {_kind, name, _id} -> String.downcase(name) end)

    if Enum.all?(entries, fn {_kind, name, _id} -> safe_name?(name) end) and
         length(Enum.uniq(folded)) == length(folded),
       do: {:ok, entries},
       else: {:error, "tree #{hex(id)} has an unsafe entry name"}
  end

  defp safe_name?(name) do
    folded = String.replace(String.downcase(name), ~r/[. ]+\z/, "")

    name not in [".", ".."] and folded not in [".git", "git~1"] and
      not String.contains?(name, ["/", "\\"])
  end

  # The tree a commit, tag or tree id stands for.
  defp root_tree(db, hex) do
    case ObjectId.from_hex(hex) do
      {:ok, id} -> peel(db, id, Object.max_peel())
      :error -> {:error, "not an object id"}
    end
  end

  defp peel(_db, _id, 0), do: {:error, "tag chain too long"}

  defp peel(db, id, n) do
    case ObjectDB.lookup(db, id) do
      {:ok, :tree, _size} ->
        {:ok, id}

      {:ok, type, _size} when type in [:commit, :tag] ->
        with {:ok, ^type, content} <- ObjectDB.read(db, id),
             {:ok, [{_type, target} | _]} <- Object.parse_links(type, content) do
          peel(db, target, n - 1)
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, "cannot read #{hex(id)}"}
        end

      {:ok, :blob, _size} ->
        {:error, "#{hex(id)} is a blob"}

      :error ->
        {:error, "no object #{hex(id)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hex(id), do: ObjectId.to_hex(id)
end
