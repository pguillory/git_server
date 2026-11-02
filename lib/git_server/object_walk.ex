defmodule GitServer.ObjectWalk do
  @moduledoc """
  Walks the object graph of a `GitServer.ObjectDB`: commits to their trees and parents,
  trees to their entries, tags to their targets. Gitlinks live in another repository
  and are not followed. Blobs are only checked for presence, never read.
  """

  alias GitServer.{ObjectDB, ObjectId}

  @doc """
  Every object reachable from `roots`, not going through any id in the set `exclude`:
  `{:ok, ids}`, each id once, or `{:error, reason}` if an object is missing, of the
  wrong type, or unreadable.
  """
  @spec reachable(ObjectDB.t(), [ObjectId.t()], MapSet.t()) ::
          {:ok, [ObjectId.t()]} | {:error, String.t()}
  def reachable(db, roots, exclude \\ MapSet.new()) do
    with {:ok, ids} <- walk(db, roots, exclude, [], &{:cont, [&1 | &2]}) do
      {:ok, Enum.reverse(ids)}
    end
  end

  @doc """
  Looks for the set of `targets` among the objects reachable from `roots`, stopping as
  soon as all are found: `{:ok, not_found}`, the set of those it did not find, or
  `{:error, reason}`.
  """
  @spec find(ObjectDB.t(), [ObjectId.t()], MapSet.t()) ::
          {:ok, MapSet.t()} | {:error, String.t()}
  def find(db, roots, targets) do
    walk(db, roots, MapSet.new(), targets, fn id, not_found ->
      not_found = MapSet.delete(not_found, id)
      if MapSet.size(not_found) == 0, do: {:halt, not_found}, else: {:cont, not_found}
    end)
  end

  defp walk(db, roots, seen, acc, visit) do
    loop(db, Enum.map(roots, &{:any, &1}), seen, acc, visit)
  end

  defp loop(_db, [], _seen, acc, _visit) do
    {:ok, acc}
  end

  defp loop(db, [{type, id} | stack], seen, acc, visit) do
    if MapSet.member?(seen, id) do
      loop(db, stack, seen, acc, visit)
    else
      with {:ok, links} <- links(db, type, id) do
        case visit.(id, acc) do
          {:cont, acc} ->
            seen = MapSet.put(seen, id)
            unseen = Enum.reject(links, fn {_type, id} -> MapSet.member?(seen, id) end)
            loop(db, unseen ++ stack, seen, acc, visit)

          {:halt, acc} ->
            {:ok, acc}
        end
      end
    end
  end

  defp links(db, :blob, id) do
    if ObjectDB.member?(db, id), do: {:ok, []}, else: missing(id)
  end

  # A root of unknown type may be a blob, which stays unread.
  defp links(db, :any, id) do
    case ObjectDB.lookup(db, id) do
      {:ok, :blob, _size} -> {:ok, []}
      {:ok, type, _size} -> links(db, type, id)
      :error -> missing(id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp links(db, type, id) do
    case ObjectDB.read(db, id) do
      {:ok, ^type, content} ->
        ObjectDB.parse_links(type, content)

      {:ok, other, _content} ->
        {:error, "object #{ObjectId.to_hex(id)} is a #{other}, expected a #{type}"}

      :error ->
        missing(id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp missing(id) do
    {:error, "missing object #{ObjectId.to_hex(id)}"}
  end
end
