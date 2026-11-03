defmodule GitServer.Config do
  @moduledoc """
  The options `GitServer.Plug` serves with, resolved on every request so no secret
  is compiled into a host's router.

  - `:store` (required): a `GitServer.Store`, such as one from `GitServer.Store.S3.new/1`.
  - `:authorize` (required): a function of one map, see `GitServer.Plug`.
  - `:temp_dir`: where request files go (default `System.tmp_dir!/0`).
  - `:max_pack_bytes`: the largest pack a push may send (default 100 MB).
  - `:max_objects`: the most objects in a pushed pack (default 100,000).
  - `:max_object_bytes`: the largest object, inflated, in a push or a stored pack
    (default 50 MB).
  - `:max_delta_depth`: the longest delta chain, in a push or a stored pack
    (default 100).
  - `:max_request_bytes`: the largest upload-pack request body, raw and inflated
    (default 10 MB).
  - `:max_command_bytes`: the largest command section of a push (default 1 MB).
  - `:push_deadline_ms`: how long a push keeps retrying its state write while other
    pushes to the same repository win the race (default 15 seconds).
  - `:before_update`: a function of one `GitServer.Push`, called before a push
    changes anything, returning `:ok` or `{:reject, message}` (default none). See
    "Checking a push" in `GitServer.ReceivePack`, and `GitServer.Push`.
  - `:before_update_timeout_ms`: how long one call of `:before_update` may run
    before the push is refused (default 30 seconds).
  """

  @enforce_keys [:store, :authorize, :temp_dir]
  defstruct [
    :store,
    :authorize,
    :temp_dir,
    max_pack_bytes: 100_000_000,
    max_objects: 100_000,
    max_object_bytes: 50_000_000,
    max_delta_depth: 100,
    max_request_bytes: 10_000_000,
    max_command_bytes: 1_000_000,
    push_deadline_ms: 15_000,
    before_update: nil,
    before_update_timeout_ms: 30_000,
  ]

  @doc """
  Builds the config from the Plug's options: either the options themselves, or
  `config: {module, function, args}` or `config: fun` (no arguments) returning
  them as a keyword list or map. Raises on a missing or unknown option, which is a
  bug in the host.
  """
  def resolve(opts) do
    opts =
      case Keyword.fetch(opts, :config) do
        {:ok, {module, function, args}} -> apply(module, function, args)
        {:ok, fun} when is_function(fun, 0) -> fun.()
        :error -> opts
      end

    opts = Map.new(opts)

    unless match?({_module, _config}, opts[:store]) and is_function(opts[:authorize], 1) do
      raise ArgumentError,
            "GitServer.Plug needs a :store and an :authorize function of one argument"
    end

    unless opts[:before_update] == nil or is_function(opts[:before_update], 1) do
      raise ArgumentError, "GitServer.Plug's :before_update must be a function of one argument"
    end

    struct!(__MODULE__, Map.put_new_lazy(opts, :temp_dir, &System.tmp_dir!/0))
  end

  @doc """
  The limits for indexing a pushed pack (`GitServer.Pack.Indexer`). The pack size and
  object count apply only to pushes, never to a stored pack.
  """
  def push_limits(%__MODULE__{} = config) do
    [
      max_pack_bytes: config.max_pack_bytes,
      max_objects: config.max_objects,
      max_object_bytes: config.max_object_bytes,
      max_delta_depth: config.max_delta_depth,
    ]
  end

  @doc """
  The options for reading a repository's stored packs (`GitServer.ObjectDB`): the
  limits, and a log label naming the repository.
  """
  def read_options(%__MODULE__{} = config, repo) do
    [
      max_object_bytes: config.max_object_bytes,
      max_delta_depth: config.max_delta_depth,
      log_label: "repository #{repo}",
    ]
  end
end
