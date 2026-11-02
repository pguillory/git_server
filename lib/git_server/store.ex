defmodule GitServer.Store do
  @moduledoc """
  The object store a repository lives in: a behaviour for stores of keyed objects
  with conditional writes, and the functions that call one. `GitServer.Store.S3` is
  the implementation (Cloudflare R2, MinIO or any S3 API). The layer knows nothing
  about Git or its callers' keys.

  A store is `{module, config}`. A failure is `{:error, :not_found}`,
  `{:error, :precondition_failed}` (a conditional write lost), or
  `{:error, message}` for anything else. Messages never hold a secret, or anything
  from a response body or header.
  """

  @type t :: {module(), term()}
  @type reason :: :not_found | :precondition_failed | String.t()
  @type etag :: String.t()
  @type condition :: :none | :absent | {:etag, etag()}
  @type object :: %{key: String.t(), etag: etag(), size: non_neg_integer()}

  @callback get(term(), String.t()) :: {:ok, binary(), etag()} | {:error, reason()}
  @callback get_file(term(), String.t(), Path.t()) :: {:ok, etag()} | {:error, reason()}
  @callback put(term(), String.t(), iodata(), condition()) :: {:ok, etag()} | {:error, reason()}
  @callback put_file(term(), String.t(), Path.t(), condition()) ::
              {:ok, etag()} | {:error, reason()}
  @callback delete(term(), String.t()) :: :ok | {:error, reason()}
  @callback list(term(), String.t()) :: {:ok, [object()]} | {:error, reason()}
  @callback describe(term()) :: String.t()

  @doc "Gets `key` whole, with its ETag."
  def get({mod, config}, key) do
    mod.get(config, key)
  end

  @doc """
  Gets `key` into a new file at `path`, streamed so it is never held in memory.
  On any error the file is removed.
  """
  def get_file({mod, config}, key, path) do
    mod.get_file(config, key, path)
  end

  @doc """
  Puts `key`: unconditionally (`:none`), only if it does not exist (`:absent`), or
  only if its current ETag is `etag` (`{:etag, etag}`). Returns the new ETag. A lost
  condition is `{:error, :precondition_failed}`.
  """
  def put({mod, config}, key, body, condition) do
    mod.put(config, key, body, condition)
  end

  @doc "Puts the contents of the file at `path`, streamed, with the same conditions as `put/4`."
  def put_file({mod, config}, key, path, condition) do
    mod.put_file(config, key, path, condition)
  end

  @doc "Deletes `key`. Deleting a missing key is `:ok`."
  def delete({mod, config}, key) do
    mod.delete(config, key)
  end

  @doc "Every object whose key starts with `prefix`, sorted by key."
  def list({mod, config}, prefix) do
    mod.list(config, prefix)
  end

  @doc "A description of the store for logs: its kind and location, never a secret."
  def describe({mod, config}) do
    mod.describe(config)
  end
end
