defmodule GitServer.TestServer do
  @moduledoc """
  Serves `GitServer.Plug` with Bandit on 127.0.0.1 and a free port, for the real
  git client.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @user "user"
  @password "secret"

  @doc """
  Starts a server for the current test, with `opts` over the defaults: this test's
  own store (`GitServer.TestStore.fresh/0`) and an authorize function that accepts
  `user`/`secret`. Returns `%{url: base_url, store: store}`; `url(server, repo)`
  builds a repository URL with credentials.
  """
  def start!(opts \\ []) do
    store = Keyword.get_lazy(opts, :store, &GitServer.TestStore.fresh/0)
    opts = Keyword.merge([store: store, authorize: &authorize/1], opts)

    pid =
      start_supervised!(
        {Bandit,
         plug: {GitServer.Plug, opts},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{url: "http://127.0.0.1:#{port}", store: store}
  end

  @doc "A repository URL with credentials (`user`/`secret` unless given)."
  def url(server, repo, user \\ @user, password \\ @password) do
    String.replace(server.url, "http://", "http://#{user}:#{password}@") <> "/" <> repo
  end

  defp authorize(%{credentials: {@user, @password}}) do
    :ok
  end

  defp authorize(_request) do
    :unauthorized
  end
end
