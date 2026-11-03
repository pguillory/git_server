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
  - `:max_fetch_work_bytes`: how much work one fetch may spend resolving the delta
    bases under the objects it reads, in bytes inflated and produced, beyond an
    allowance of twice `max_delta_depth` times the bytes it reads (default 1 GB). The
    objects themselves never count. So a history of large files changed many times
    stays within it, while a pack built to make a fetch resolve the same long chains
    again and again for little output doesn't.
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
  - `:after_update`: a function of one map, called once after a push has landed,
    for webhooks, CI triggers and notifications (default none). See
    `GitServer.ReceivePack`.
  - `:after_update_timeout_ms`: how long one call of `:after_update` may run before
    it is killed (default 30 seconds).
  - `:download_concurrency`: how many store downloads one request runs at once, a
    positive integer (default 8). A fetch or push downloads every pack and idx the
    repository lists. Each download holds a store connection, and the S3 store's
    connection pool holds 50 per endpoint, a request waiting at most 5 s for one.
  - `:pack_cache_dir`: a directory for a local cache of stored packs, so a fetch or
    push downloads only packs it hasn't seen (default none: no cache). See
    `GitServer.PackCache`. Made private to this user if it doesn't exist; it must be
    private to this user and hold nothing else, and not be named `git_server-*`, the
    name of request directories. If it can't be used, requests log it and go on
    without the cache.
  - `:pack_cache_bytes`: the size the cache is kept under (default 1 GB).
  """

  @enforce_keys [:store, :authorize, :temp_dir]
  @defaults [
    max_pack_bytes: 100_000_000,
    max_objects: 100_000,
    max_object_bytes: 50_000_000,
    max_delta_depth: 100,
    max_fetch_work_bytes: 1_000_000_000,
    max_request_bytes: 10_000_000,
    max_command_bytes: 1_000_000,
    push_deadline_ms: 15_000,
    before_update: nil,
    before_update_timeout_ms: 30_000,
    after_update: nil,
    after_update_timeout_ms: 30_000,
    download_concurrency: 8,
    pack_cache_dir: nil,
    pack_cache_bytes: 1_000_000_000,
  ]
  defstruct @enforce_keys ++ @defaults
  @fields @enforce_keys ++ Keyword.keys(@defaults)

  @doc """
  Builds the config from the Plug's options: either the options themselves, or
  `config: {module, function, args}` or `config: fun` (no arguments) returning
  them as a keyword list or map. Returns `{:ok, config}`, or `{:error, description}`
  for the log when the function fails or the options are wrong, which is a bug in
  the host. The description never holds an option's value or anything a failure
  carries (see `GitServer.Failure`), since the options hold the store's secrets.
  """
  def resolve(opts) do
    with {:ok, opts} <- call(Keyword.fetch(opts, :config), opts) do
      validate(Map.new(opts))
    end
  end

  defp call(:error, opts), do: {:ok, opts}

  defp call({:ok, {module, function, args}}, _opts) when is_atom(module) and is_list(args),
    do: call_config(fn -> apply(module, function, args) end)

  defp call({:ok, fun}, _opts) when is_function(fun, 0), do: call_config(fun)

  defp call({:ok, _config}, _opts),
    do: {:error, "the :config option must be {module, function, args} or a function of none"}

  defp call_config(fun) do
    result = fun.()

    # A struct isn't enumerable, and an error inspecting it would print its values.
    if (is_map(result) and not is_struct(result)) or
         (is_list(result) and Keyword.keyword?(result)),
       do: {:ok, result},
       else: {:error, "the config function returned something other than a keyword list or map"}
  catch
    kind, reason ->
      {:error, "the config function " <> GitServer.Failure.describe(kind, reason, __STACKTRACE__)}
  end

  @counts [
    :max_pack_bytes,
    :max_objects,
    :max_object_bytes,
    :max_delta_depth,
    :max_fetch_work_bytes,
    :max_request_bytes,
    :max_command_bytes,
    :pack_cache_bytes,
  ]
  @durations [:push_deadline_ms, :before_update_timeout_ms, :after_update_timeout_ms]

  defp validate(opts) do
    unknown = opts |> Map.keys() |> Enum.reject(&(&1 in @fields))
    opts = Map.merge(Map.new([temp_dir: nil] ++ @defaults), opts)
    not_count = Enum.reject(@counts, &(is_integer(opts[&1]) and opts[&1] >= 0))
    not_duration = Enum.reject(@durations, &(is_integer(opts[&1]) and opts[&1] >= 0))

    cond do
      unknown != [] ->
        {:error, "unknown GitServer.Plug options: #{names(unknown)}"}

      not match?(
        {module, _config} when is_atom(module) and not is_boolean(module) and module != nil,
        opts[:store]
      ) or
          not is_function(opts[:authorize], 1) ->
        {:error, "GitServer.Plug needs a :store and an :authorize function of one argument"}

      not (opts[:before_update] == nil or is_function(opts[:before_update], 1)) ->
        {:error, "GitServer.Plug's :before_update must be a function of one argument"}

      not (opts[:after_update] == nil or is_function(opts[:after_update], 1)) ->
        {:error, "GitServer.Plug's :after_update must be a function of one argument"}

      not_count != [] ->
        {:error, "GitServer.Plug options must be non-negative integers: #{names(not_count)}"}

      not (is_integer(opts[:download_concurrency]) and opts[:download_concurrency] >= 1) ->
        {:error, "GitServer.Plug's :download_concurrency must be a positive integer"}

      not_duration != [] ->
        {:error,
         "GitServer.Plug options must be integers of milliseconds: #{names(not_duration)}"}

      not (opts[:temp_dir] == nil or is_binary(opts[:temp_dir])) ->
        {:error, "GitServer.Plug's :temp_dir must be a path"}

      not (opts[:pack_cache_dir] == nil or
               (is_binary(opts[:pack_cache_dir]) and
                  not String.starts_with?(
                    Path.basename(Path.expand(opts[:pack_cache_dir])),
                    "git_server-"
                  ))) ->
        {:error, "GitServer.Plug's :pack_cache_dir must be a path not named git_server-*"}

      true ->
        {:ok, struct!(__MODULE__, %{opts | temp_dir: opts[:temp_dir] || System.tmp_dir!()})}
    end
  end

  defp names(keys), do: Enum.map_join(keys, ", ", &inspect/1)

  @doc """
  A byte count for a message naming a limit: `"100 MB"`, `"2 KB"`, or `"1500 bytes"`.
  """
  def format_bytes(n) when rem(n, 1_000_000) == 0 and n > 0, do: "#{div(n, 1_000_000)} MB"
  def format_bytes(n) when rem(n, 1000) == 0 and n > 0, do: "#{div(n, 1000)} KB"
  def format_bytes(n), do: "#{n} bytes"

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
  The options for `GitServer.Repository.snapshot/4`: download concurrency and the
  pack cache.
  """
  def snapshot_options(%__MODULE__{} = config) do
    cache = if config.pack_cache_dir, do: {config.pack_cache_dir, config.pack_cache_bytes}
    [concurrency: config.download_concurrency, cache: cache]
  end

  @doc """
  The options for reading a repository's stored packs (`GitServer.ObjectDB`): the
  limits, and a log label naming the repository. A fetch (`fetch: true`) also has
  its work budget.
  """
  def read_options(%__MODULE__{} = config, repo, opts \\ []) do
    budget =
      if opts[:fetch], do: [max_base_work_bytes: config.max_fetch_work_bytes], else: []

    [
      max_object_bytes: config.max_object_bytes,
      max_delta_depth: config.max_delta_depth,
      log_label: "repository #{repo}",
    ] ++ budget
  end
end
