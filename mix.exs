defmodule GitServer.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :git_server,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Git smart HTTP server for Plug, storing repositories in S3.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/pguillory/git_server"},
      ],
    ]
  end

  defp elixirc_paths(:test) do
    ["lib", "test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:req, "~> 0.7"},
      {:req_s3, "~> 0.2.5"},
      {:bandit, ">= 0.0.0", only: [:dev, :test]},
      {:freedom_formatter, ">= 0.0.0", only: [:dev, :test], runtime: false},
    ]
  end
end
