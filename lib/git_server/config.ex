defmodule GitServer.Config do
  @moduledoc """
  The options `GitServer.Plug` serves with, resolved on every request so no secret
  is compiled into a host's router.

  - `:store` (required): a `GitServer.Store`, such as one from `GitServer.Store.S3.new/1`.
  - `:authorize` (required): a function of one map, see `GitServer.Plug`.
  - `:temp_dir`: where request files go (default `System.tmp_dir!/0`).
  - `:max_pack_bytes`: the largest pack a push may send (default 100 MB).
  - `:max_object_bytes`: the largest object, inflated (default 50 MB).
  - `:max_request_bytes`: the largest upload-pack request body, raw and inflated
    (default 10 MB).
  - `:max_command_bytes`: the largest command section of a push (default 1 MB).
  """

  @enforce_keys [:store, :authorize, :temp_dir]
  defstruct [
    :store,
    :authorize,
    :temp_dir,
    max_pack_bytes: 100_000_000,
    max_object_bytes: 50_000_000,
    max_request_bytes: 10_000_000,
    max_command_bytes: 1_000_000,
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

    struct!(__MODULE__, Map.put_new_lazy(opts, :temp_dir, &System.tmp_dir!/0))
  end
end
