defmodule GitServer.Shallow do
  @moduledoc """
  The shallow part of a v2 fetch (gitprotocol-v2, `shallow-info`), computed the way
  git's own upload-pack computes it.

  The client names the commits it has without their parents (`shallow`), and may ask
  for a new boundary: `deepen <n>` (commits within `n` parent steps of the wants, or of
  the client's shallow commits with `deepen-relative`) or `deepen-since <time>`
  (commits whose committer time is at least `time`). The commits where the new history
  stops are sent as `shallow`, and client shallow commits now inside it as
  `unshallow`.

  `cut` holds the client's shallow commits and the new boundary, and both walks of the
  fetch (from the wants, and from the haves) treat every commit in it as parentless.
  An unshallowed commit's parents are walked as extra wants, and the commit itself is
  excluded, since the client has it.

  The new boundary is found by a walk of commits only, from commits the client may
  fetch (the wants, which are already checked against the refs, or for
  `deepen-relative` the client's shallow commits a ref reaches), so a client never
  learns about history no ref reaches. Its cost is the number of commits it visits,
  however large the depth asked for; `deepen-relative` also walks the whole graph from
  the refs once, to find which of the client's shallow commits they reach.

  Unlike git's, an `--unshallow` only clears client shallow commits the wants reach:
  one left behind by a force push to unrelated history, or one on a branch not
  fetched, stays in the client's `.git/shallow`.
  """

  alias GitServer.Object
  alias GitServer.ObjectDB
  alias GitServer.ObjectId
  alias GitServer.ObjectWalk

  # git's INFINITE_DEPTH, what `git fetch --unshallow` sends.
  @max_depth 0x7FFFFFFF

  defstruct cut: MapSet.new(), shallow: [], unshallow: [], unshallow_parents: [], info: false

  @typedoc """
  `cut`: commits both walks treat as parentless. `shallow` and `unshallow`: the lines
  to send. `unshallow_parents`: extra roots of the walk from the wants. `info`: whether a
  `shallow-info` section is sent.
  """
  @type t :: %__MODULE__{
          cut: MapSet.t(),
          shallow: [ObjectId.t()],
          unshallow: [ObjectId.t()],
          unshallow_parents: [ObjectId.t()],
          info: boolean,
        }

  @doc "The largest `deepen` a client may send."
  def max_depth do
    @max_depth
  end

  @doc """
  The client's `shallow` commits that the repository holds. As git does, one it lacks
  is ignored and one that isn't a commit is an error.
  """
  @spec client_shallows(ObjectDB.t(), [ObjectId.t()]) ::
          {:ok, [ObjectId.t()]} | {:error, String.t()}
  def client_shallows(db, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case ObjectDB.lookup(db, id) do
        {:ok, :commit, _size} -> {:cont, {:ok, [id | acc]}}
        {:ok, _type, _size} -> {:halt, {:error, "invalid shallow object #{ObjectId.to_hex(id)}"}}
        :error -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  The shallow plan for a fetch of `wants` by a client with the `shallows` commits
  (from `client_shallows/2`). `request` has `:depth` (nil or 1 to `max_depth/0`),
  `:relative` and `:since` (nil or a Unix time); `tips` are the ref tips, for
  `deepen-relative`.
  """
  @spec plan(ObjectDB.t(), [ObjectId.t()], [ObjectId.t()], [ObjectId.t()], map) ::
          {:ok, t} | {:error, String.t()}
  def plan(db, tips, wants, shallows, request) do
    client = MapSet.new(shallows)
    info = request.depth != nil or request.since != nil or shallows != []

    with {:ok, boundary, inside} <- boundary(db, tips, wants, shallows, request),
         unshallow = Enum.filter(shallows, &MapSet.member?(inside, &1)),
         {:ok, parents} <- parents_of(db, unshallow) do
      shallow = Enum.reject(boundary, &MapSet.member?(client, &1))

      {:ok,
       %__MODULE__{
         cut: MapSet.union(client, MapSet.new(shallow)),
         shallow: shallow,
         unshallow: unshallow,
         unshallow_parents: parents,
         info: info,
       }}
    end
  end

  # `{:ok, boundary, inside}`: the commits where the new history stops, and the set of
  # commits inside it whose parents are all sent. No deepen: no new boundary.
  defp boundary(db, tips, wants, shallows, %{depth: depth, relative: relative, since: since}) do
    cond do
      depth != nil and relative ->
        with {:ok, starts} <- reachable_shallows(db, tips, shallows) do
          by_depth(db, starts, depth)
        end

      depth != nil ->
        with {:ok, starts} <- want_commits(db, wants) do
          by_depth(db, starts, depth - 1)
        end

      since != nil ->
        with {:ok, starts} <- want_commits(db, wants) do
          by_time(db, starts, since)
        end

      true ->
        {:ok, [], MapSet.new()}
    end
  end

  # Level by level from `starts` (level 0), so each commit is seen at its shortest
  # distance. Commits at level `last` are the boundary; those before it are inside.
  # The deepest a client can ask for has no boundary at all.
  defp by_depth(db, starts, last) do
    starts = Enum.uniq(starts)
    # The deepest request leaves `last` at `@max_depth - 1` (plain) or `@max_depth`
    # (relative): no boundary either way.
    last = if last >= @max_depth - 1, do: :infinity, else: last
    levels(db, starts, 0, last, MapSet.new(starts), MapSet.new())
  end

  defp levels(_db, [], _level, _last, _seen, inside) do
    {:ok, [], inside}
  end

  defp levels(_db, frontier, level, level, _seen, inside) do
    {:ok, frontier, inside}
  end

  defp levels(db, frontier, level, last, seen, inside) do
    result =
      Enum.reduce_while(frontier, {:ok, [], seen}, fn id, {:ok, next, seen} ->
        case parents(db, id) do
          {:ok, parents} ->
            new = parents |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1))
            {:cont, {:ok, Enum.reverse(new, next), Enum.reduce(new, seen, &MapSet.put(&2, &1))}}

          error ->
            {:halt, error}
        end
      end)

    with {:ok, next, seen} <- result do
      inside = Enum.reduce(frontier, inside, &MapSet.put(&2, &1))
      levels(db, Enum.reverse(next), level + 1, last, seen, inside)
    end
  end

  # As `git rev-list --max-age=<since> <wants>`: the commits reached from the wants
  # through commits no older than `since`. The boundary is those with a parent left
  # out.
  defp by_time(db, starts, since) do
    with {:ok, included} <- recent(db, Enum.uniq(starts), since, %{}) do
      if map_size(included) == 0 do
        {:error, "no commits selected for shallow requests"}
      else
        boundary =
          for {id, parents} <- included,
              Enum.any?(parents, &(not Map.has_key?(included, &1))),
              do: id

        inside = included |> Map.keys() |> MapSet.new() |> MapSet.difference(MapSet.new(boundary))
        {:ok, Enum.sort(boundary), inside}
      end
    end
  end

  # `included` maps each recent commit to its parents, and each one too old to `false`,
  # so it is read once; those are dropped at the end.
  defp recent(_db, [], _since, included) do
    {:ok, for({id, parents} <- included, parents != false, into: %{}, do: {id, parents})}
  end

  defp recent(db, [id | stack], since, included) do
    if Map.has_key?(included, id) do
      recent(db, stack, since, included)
    else
      with {:ok, parents, time} <- commit(db, id) do
        if time >= since do
          recent(db, parents ++ stack, since, Map.put(included, id, parents))
        else
          recent(db, stack, since, Map.put(included, id, false))
        end
      end
    end
  end

  # The client's shallow commits some ref reaches. A walk of the whole graph, but only
  # for `deepen-relative`.
  defp reachable_shallows(_db, _tips, []) do
    {:ok, []}
  end

  defp reachable_shallows(db, tips, shallows) do
    with {:ok, not_found} <- ObjectWalk.find(db, tips, MapSet.new(shallows)) do
      {:ok, Enum.reject(shallows, &MapSet.member?(not_found, &1))}
    end
  end

  # The wants as commits: a tag is followed to what it tags, within the peel bound, and
  # a want that isn't a commit in the end has no history to cut.
  defp want_commits(db, wants) do
    Enum.reduce_while(wants, {:ok, []}, fn id, {:ok, acc} ->
      case peel(db, id, Object.max_peel()) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, commit} -> {:cont, {:ok, [commit | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp peel(_db, _id, 0) do
    {:ok, nil}
  end

  defp peel(db, id, n) do
    case ObjectDB.lookup(db, id) do
      {:ok, :commit, _size} ->
        {:ok, id}

      {:ok, :tag, _size} ->
        with {:ok, :tag, content} <- read(db, id),
             {:ok, [{_type, target}]} <- ObjectDB.parse_links(:tag, content) do
          peel(db, target, n - 1)
        end

      {:ok, _type, _size} ->
        {:ok, nil}

      :error ->
        missing(id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parents_of(db, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case parents(db, id) do
        {:ok, parents} -> {:cont, {:ok, Enum.reverse(parents, acc)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp parents(db, id) do
    with {:ok, parents, _time} <- commit(db, id), do: {:ok, parents}
  end

  # A commit's parents and committer time.
  defp commit(db, id) do
    with {:ok, :commit, content} <- read(db, id),
         {:ok, [{:tree, _tree} | parents]} <- ObjectDB.parse_links(:commit, content) do
      {:ok, Enum.map(parents, fn {:commit, parent} -> parent end), committer_time(content)}
    else
      {:ok, type, _content} ->
        {:error, "object #{ObjectId.to_hex(id)} is a #{type}, expected a commit"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read(db, id) do
    case ObjectDB.read(db, id) do
      :error -> missing(id)
      result -> result
    end
  end

  @max_time_digits 19

  @doc """
  The committer time of a commit's content, in seconds since the epoch, or 0 when it
  can't be read, as git reads it: the number after the last `>` of the `committer`
  header. Only the headers are searched, nothing is allocated per byte, and the number
  has at most 19 digits.
  """
  @spec committer_time(binary) :: non_neg_integer
  def committer_time(content) do
    [headers | _] = :binary.split(content, "\n\n")

    with [_, rest] <- :binary.split(headers, "\ncommitter "),
         [line | _] <- :binary.split(rest, "\n"),
         {:ok, after_email} <- after_last(line, ?>),
         " " <> date <- after_email,
         [digits | _] <- :binary.split(date, " "),
         true <- byte_size(digits) <= @max_time_digits,
         true <- String.match?(digits, ~r/\A[0-9]+\z/) do
      String.to_integer(digits)
    else
      _ -> 0
    end
  end

  # What follows the last `byte` in `binary`, found scanning back from the end.
  defp after_last(binary, byte) do
    after_last(binary, byte, byte_size(binary))
  end

  defp after_last(_binary, _byte, 0) do
    :error
  end

  defp after_last(binary, byte, i) do
    case :binary.at(binary, i - 1) do
      ^byte -> {:ok, binary_part(binary, i, byte_size(binary) - i)}
      _ -> after_last(binary, byte, i - 1)
    end
  end

  defp missing(id) do
    {:error, "missing object #{ObjectId.to_hex(id)}"}
  end
end
