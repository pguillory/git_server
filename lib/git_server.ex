defmodule GitServer do
  @moduledoc """
  A Git smart HTTP server, mounted as a Plug, that stores repositories in S3.

  See `GitServer.Plug`.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Compacts a repository: merges its small packs into one, keeping every object, so
  fetches and pushes download few packs however many pushes there have been. It
  deletes nothing: the merged packs stay in the store, no longer listed.

  `opts` are `GitServer.Plug`'s options (or `config:` naming a function returning
  them), for the store, `:temp_dir`, the pack cache, the object limits, and
  `:push_deadline_ms`, how long compaction retries its state write while pushes
  win. `repo` is a repository name, such as `"alice/notes"`. `compact_opts`:

    * `:max_packs` - nothing is merged while the repository lists at most this many
      packs (default 8)
    * `:max_compact_bytes` - the largest pack one compaction writes, and the most
      bytes of packs it merges (default 1 GB); larger packs are never merged
    * `:max_compact_objects` - the most objects one compaction merges, which bounds
      its memory (default 500,000)

  Which packs merge follows `git repack --geometric=2`: the smallest packs roll up
  until each pack left is at least twice the size of the next smaller one, so the
  number of packs, and the bytes rewritten per push, stay logarithmic.

  Returns `{:ok, %{merged: n, packs: m}}` once `n` packs were replaced by one and
  the repository lists `m`; `{:ok, :unchanged}` when there was nothing to merge;
  `{:ok, :superseded}` when another compaction retired one of the packs first;
  `{:ok, :busy}` when another compaction of the repository is running on this node;
  or `{:error, reason}`. It's safe to run at any time, alongside pushes, fetches and
  other compactions, on any number of servers. Nothing calls it automatically: call
  it on a schedule, or after pushes from `:after_update`.
  """
  def compact(opts, repo, compact_opts \\ []) do
    GitServer.Compaction.run(opts, repo, compact_opts)
  end

  @doc "The library version, as sent in the `agent` capability."
  def version do
    @version
  end
end
