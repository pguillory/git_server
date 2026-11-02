defmodule GitServer.Store.S3 do
  @moduledoc """
  Objects in an S3-compatible bucket (Cloudflare R2, MinIO, or any S3 API), through
  `ReqS3`. A key `k` is the object `<prefix>k`, addressed path-style
  (`<endpoint>/<bucket>/<prefix>k`; `ReqS3` uses virtual-host style for an
  `s3.amazonaws.com` endpoint). Listing is scoped to the prefix.

  `new/1` checks the settings this client is safe with (`check_endpoint/1`,
  `check_prefix/1`). Keys are not validated here, only encoded segment by segment:
  key safety is the caller's job.

  A failed call is `:not_found`, `:precondition_failed` (HTTP 409 or 412) or a
  message, and requests are not retried. Timeouts: 5 s to connect, 15 s to receive
  each part of a response. Nothing from a response body or header is ever logged or
  returned in an error.
  """

  @behaviour GitServer.Store

  @enforce_keys [:endpoint, :bucket, :region, :prefix, :access_key_id, :secret_access_key]
  @derive {Inspect, except: [:secret_access_key]}
  defstruct @enforce_keys

  @connect_timeout 5_000
  @chunk_bytes 65_536

  @doc """
  A store from options `:endpoint`, `:bucket`, `:region`, `:access_key_id`,
  `:secret_access_key` and optional `:prefix` (default `""`). Returns
  `{:ok, {GitServer.Store.S3, config}}`, or `{:error, message}` when an option is
  missing or fails its check.
  """
  def new(opts) do
    opts = Map.new(opts)
    config = Map.put_new(opts, :prefix, "")

    missing =
      Enum.reject(@enforce_keys, &(is_binary(config[&1]) and (&1 == :prefix or config[&1] != "")))

    cond do
      missing != [] -> {:error, "missing S3 settings: #{Enum.join(missing, ", ")}"}
      (message = endpoint_error(config.endpoint)) != nil -> {:error, message}
      (message = prefix_error(config.prefix)) != nil -> {:error, message}
      true -> {:ok, {__MODULE__, struct!(__MODULE__, Map.take(config, @enforce_keys))}}
    end
  end

  defp endpoint_error(endpoint) do
    case check_endpoint(endpoint) do
      :ok ->
        nil

      {:error, :not_url} ->
        "the S3 endpoint must be an http(s)://host URL with nothing after the host and port"

      {:error, :insecure} ->
        "the S3 endpoint must use https unless it is on this machine"
    end
  end

  defp prefix_error(prefix) do
    case check_prefix(prefix) do
      :ok -> nil
      {:error, :no_trailing_slash} -> "the S3 prefix must end in /"
      {:error, :invalid_characters} -> "the S3 prefix may use only letters, digits and . _ ~ / -"
    end
  end

  @doc """
  Checks an endpoint: `:ok`, `{:error, :not_url}` unless it is an `http(s)://<host>`
  URL with no path, user info, query or fragment, or `{:error, :insecure}` for
  `http://` anywhere but this machine (the host `localhost`, 127.0.0.0/8 or
  `[::1]`), so no one on the network path can read or rewrite what the store
  returns.
  """
  def check_endpoint(endpoint) do
    uri = URI.parse(endpoint)

    cond do
      uri.scheme not in ["https", "http"] or uri.host in [nil, ""] or uri.path not in [nil, ""] or
        uri.userinfo != nil or uri.query != nil or uri.fragment != nil ->
        {:error, :not_url}

      uri.scheme == "http" and not loopback?(uri.host) ->
        {:error, :insecure}

      true ->
        :ok
    end
  end

  # Only the plain loopback forms: `localhost`, 127.0.0.0/8 and ::1. Not a name that
  # merely starts with them, and not an IPv4-mapped IPv6 address.
  defp loopback?("localhost") do
    true
  end

  defp loopback?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  @doc """
  Checks a key prefix: `:ok`, `{:error, :no_trailing_slash}` for a non-empty prefix
  not ending in `/`, or `{:error, :invalid_characters}` unless it uses only letters,
  digits and `. _ ~ / -`.
  """
  def check_prefix(prefix) do
    cond do
      prefix != "" and not String.ends_with?(prefix, "/") -> {:error, :no_trailing_slash}
      not String.match?(prefix, ~r{\A[A-Za-z0-9._~/-]*\z}) -> {:error, :invalid_characters}
      true -> :ok
    end
  end

  @impl true
  def describe(config) do
    "S3 bucket #{config.bucket} at #{config.endpoint}, prefix #{inspect(config.prefix)}"
  end

  @impl true
  def get(config, key) do
    # Bytes as stored, whatever the object's name or content type suggests.
    case request(config, :get, object_url(config, key), decode_body: false) do
      {:ok, %{status: 200} = response} ->
        with {:ok, etag} <- response_etag(response), do: {:ok, response.body, etag}

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def get_file(config, key, path) do
    case File.open(path, [:write, :exclusive, :raw, :binary]) do
      {:ok, file} ->
        result =
          try do
            get_into(config, key, file)
          after
            File.close(file)
          end

        with {:error, _} <- result, do: File.rm(path)
        result

      {:error, posix} ->
        {:error, "cannot create #{path}: #{:file.format_error(posix)}"}
    end
  end

  # Writes the body to `file` only for a 200, so an error body never lands in it.
  defp get_into(config, key, file) do
    into = fn {:data, data}, {request, response} ->
      if response.status == 200 do
        case IO.binwrite(file, data) do
          :ok ->
            {:cont, {request, response}}

          {:error, posix} ->
            {:halt, {request, Req.Response.put_private(response, :write_error, posix)}}
        end
      else
        {:cont, {request, response}}
      end
    end

    case request(config, :get, object_url(config, key), decode_body: false, into: into) do
      {:ok, %{status: 200} = response} ->
        case Req.Response.get_private(response, :write_error) do
          nil -> response_etag(response)
          posix -> {:error, "cannot write the downloaded object: #{:file.format_error(posix)}"}
        end

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def put(config, key, body, condition) do
    put_request(config, key, condition, body: body)
  end

  @impl true
  def put_file(config, key, path, condition) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        # A streamed body is signed as UNSIGNED-PAYLOAD, which needs an explicit length.
        put_request(config, key, condition,
          body: File.stream!(path, @chunk_bytes),
          headers: [{"content-length", Integer.to_string(size)}]
        )

      {:ok, _stat} ->
        {:error, "#{path} is not a regular file"}

      {:error, posix} ->
        {:error, "cannot read #{path}: #{:file.format_error(posix)}"}
    end
  end

  defp put_request(config, key, condition, options) do
    condition_headers =
      case condition do
        :none -> []
        :absent -> [{"if-none-match", "*"}]
        {:etag, etag} -> [{"if-match", quote_etag(etag)}]
      end

    options = Keyword.update(options, :headers, condition_headers, &(condition_headers ++ &1))

    case request(config, :put, object_url(config, key), options) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        response_etag(response)

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def delete(config, key) do
    case request(config, :delete, object_url(config, key), []) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status}} -> {:error, status_error(status)}
      {:error, message} -> {:error, message}
    end
  end

  @impl true
  def list(config, prefix) do
    list_pages(config, config.prefix <> prefix, nil, [])
  end

  # The bare bucket URL is what makes ReqS3 parse the listing's XML.
  defp list_pages(config, full_prefix, token, pages) do
    params =
      [{"list-type", "2"}, {"prefix", full_prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case request(config, :get, "s3://#{config.bucket}", params: params) do
      {:ok, %{status: 200, body: %{"ListBucketResult" => listing}}} ->
        pages = [Enum.map(List.wrap(listing["Contents"]), &object(&1, config.prefix)) | pages]

        if listing["IsTruncated"] == "true" do
          list_pages(config, full_prefix, listing["NextContinuationToken"], pages)
        else
          {:ok, pages |> Enum.concat() |> Enum.sort_by(& &1.key)}
        end

      {:ok, %{status: 200}} ->
        {:error, "store request failed (unexpected listing)"}

      {:ok, %{status: status}} ->
        {:error, status_error(status)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp object(contents, prefix) do
    %{
      key: String.replace_prefix(contents["Key"], prefix, ""),
      etag: String.trim(contents["ETag"], "\""),
      size: String.to_integer(contents["Size"]),
    }
  end

  defp request(config, method, url, options) do
    request =
      [
        method: method,
        url: url,
        aws_sigv4: [
          access_key_id: config.access_key_id,
          secret_access_key: config.secret_access_key,
          region: config.region,
        ],
        retry: false,
        redirect: false,
        compressed: false,
        connect_options: [timeout: @connect_timeout],
      ]
      |> Req.new()
      |> ReqS3.attach(aws_endpoint_url_s3: config.endpoint)

    case Req.request(request, options) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, "store request failed (#{Exception.message(exception)})"}
    end
  end

  defp status_error(404) do
    :not_found
  end

  defp status_error(status) when status in [409, 412] do
    :precondition_failed
  end

  defp status_error(status) do
    "store request failed (HTTP #{status})"
  end

  defp object_url(config, key) do
    encoded =
      (config.prefix <> key)
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

    "s3://#{config.bucket}/#{encoded}"
  end

  defp quote_etag(etag) do
    ~s("#{etag}")
  end

  defp response_etag(response) do
    case Req.Response.get_header(response, "etag") do
      [etag | _] -> {:ok, etag |> String.trim_leading("W/") |> String.trim("\"")}
      [] -> {:error, "store response has no ETag"}
    end
  end
end
