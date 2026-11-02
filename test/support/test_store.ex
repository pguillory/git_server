defmodule GitServer.TestStore do
  @moduledoc """
  The real S3 store the tests use. Settings come from the `GIT_SERVER_TEST_S3_*`
  environment variables or, when those are unset, from `tmp/test-s3.env`, which
  `bin/test-s3-local start` writes for MinIO on loopback. Every run gets its own
  random prefix `test-<random>/`, which `cleanup/0` deletes at the end.
  """

  @vars ~w(ENDPOINT BUCKET REGION ACCESS_KEY_ID SECRET_ACCESS_KEY)
  @env_file "tmp/test-s3.env"

  @doc "Loads the settings and picks this run's prefix. Raises with instructions if none exist."
  def setup! do
    settings = settings()

    if Enum.any?(@vars, &(settings[&1] in [nil, ""])) do
      raise """
      No test S3 settings. Run `bin/test-s3-local start` for MinIO on loopback, or set
      GIT_SERVER_TEST_S3_ENDPOINT, _BUCKET, _REGION, _ACCESS_KEY_ID and _SECRET_ACCESS_KEY.
      """
    end

    run_prefix = "test-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}/"

    {:ok, _store} =
      GitServer.Store.S3.new(
        endpoint: settings["ENDPOINT"],
        bucket: settings["BUCKET"],
        region: settings["REGION"],
        access_key_id: settings["ACCESS_KEY_ID"],
        secret_access_key: settings["SECRET_ACCESS_KEY"],
        prefix: run_prefix
      )
      |> tap(fn {:ok, store} -> :persistent_term.put(__MODULE__, store) end)
  end

  defp settings do
    from_env = Map.new(@vars, &{&1, System.get_env("GIT_SERVER_TEST_S3_" <> &1)})

    if Enum.all?(Map.values(from_env), &(&1 in [nil, ""])) and File.exists?(@env_file) do
      @env_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [name, value] = String.split(line, "=", parts: 2)
        {String.replace_prefix(name, "GIT_SERVER_TEST_S3_", ""), value}
      end)
    else
      from_env
    end
  end

  @doc "The run's store, scoped to its prefix."
  def store do
    :persistent_term.get(__MODULE__)
  end

  @doc "A store scoped to a fresh sub-prefix of the run's, so a test has keys of its own."
  def fresh do
    {mod, config} = store()
    sub = "#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}/"
    {mod, %{config | prefix: config.prefix <> sub}}
  end

  @doc "Deletes every object under the run's prefix."
  def cleanup do
    {:ok, objects} = GitServer.Store.list(store(), "")
    Enum.each(objects, &(:ok = GitServer.Store.delete(store(), &1.key)))
  end
end
