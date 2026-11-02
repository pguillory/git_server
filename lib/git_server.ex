defmodule GitServer do
  @moduledoc """
  A Git smart HTTP server, mounted as a Plug, that stores repositories in S3.

  See `GitServer.Plug`.
  """

  @version Mix.Project.config()[:version]

  @doc "The library version, as sent in the `agent` capability."
  def version, do: @version
end
