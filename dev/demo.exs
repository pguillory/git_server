# A demo server on http://127.0.0.1:4000 (or GIT_SERVER_DEMO_PORT), storing repositories in an S3 bucket:
#
#     mix run --no-halt dev/demo.exs
#
# bin/demo runs this with the settings filled in, for MinIO or a settings file.
#
# Settings: GIT_SERVER_S3_ENDPOINT, GIT_SERVER_S3_BUCKET, GIT_SERVER_S3_REGION,
# GIT_SERVER_S3_ACCESS_KEY_ID, GIT_SERVER_S3_SECRET_ACCESS_KEY, and optionally
# GIT_SERVER_S3_PREFIX (ending in /). Any username works with the password in
# GIT_SERVER_DEMO_PASSWORD, or with a random one printed at startup when that is
# unset. GIT_SERVER_DEMO_PORT picks another port. Plain HTTP is only acceptable
# because the server binds 127.0.0.1.
require Logger

setting = fn name -> System.get_env("GIT_SERVER_S3_" <> name) end

store =
  case GitServer.Store.S3.new(
         endpoint: setting.("ENDPOINT"),
         bucket: setting.("BUCKET"),
         region: setting.("REGION"),
         access_key_id: setting.("ACCESS_KEY_ID"),
         secret_access_key: setting.("SECRET_ACCESS_KEY"),
         prefix: setting.("PREFIX") || ""
       ) do
    {:ok, store} ->
      store

    {:error, message} ->
      IO.puts(:stderr, "demo: #{message} (set the GIT_SERVER_S3_* variables)")
      System.halt(1)
  end

password =
  case System.get_env("GIT_SERVER_DEMO_PASSWORD") do
    password when password not in [nil, ""] ->
      password

    _ ->
      password = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      IO.puts(:stderr, "demo: GIT_SERVER_DEMO_PASSWORD is unset; the password is #{password}")
      password
  end

authorize = fn
  %{credentials: {_username, given}} ->
    if Plug.Crypto.secure_compare(given, password), do: :ok, else: :unauthorized

  _request ->
    :unauthorized
end

port = String.to_integer(System.get_env("GIT_SERVER_DEMO_PORT") || "4000")

# Trapped only while starting, so a port in use is a sentence rather than a crash.
Process.flag(:trap_exit, true)

case Bandit.start_link(
       plug: {GitServer.Plug, store: store, authorize: authorize},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false
     ) do
  {:ok, _pid} ->
    Process.flag(:trap_exit, false)

  {:error, reason} ->
    IO.puts(
      :stderr,
      "demo: cannot serve on 127.0.0.1:#{port} (#{inspect(reason)}); GIT_SERVER_DEMO_PORT picks another port"
    )

    System.halt(1)
end

Logger.info("demo: serving on http://127.0.0.1:#{port} from #{GitServer.Store.describe(store)}")

# The server is linked to this process, so it must outlive the script.
Process.sleep(:infinity)
