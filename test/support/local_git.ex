defmodule GitServer.LocalGit do
  @moduledoc """
  Runs the real `git` client on local repositories, isolated from the developer's own
  setup: a temporary `HOME`, no system or global config beyond a test file, and no
  terminal prompt.
  """

  @doc "Creates an empty temporary directory. The caller removes it."
  def tmp_dir!(label) do
    dir =
      Path.join(System.tmp_dir!(), "git_server_#{label}_#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  @doc "The environment every git command runs with, rooted at `home`."
  def env(home) do
    config = Path.join(home, "gitconfig")

    unless File.exists?(config) do
      File.write!(config, """
      [user]
      \tname = Test User
      \temail = test@example.com
      [init]
      \tdefaultBranch = main
      """)
    end

    [
      {"HOME", home},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", config},
      {"GIT_TERMINAL_PROMPT", "0"},
    ]
  end

  @doc """
  Runs `git args` in `dir` and returns its standard output, raising with its standard
  error if it fails. `:input` names a file to feed on standard input.
  """
  def git!(home, dir, args, opts \\ []) do
    input = opts[:input] || "/dev/null"
    errors = Path.join(home, "git-stderr-#{System.unique_integer([:positive])}")
    script = ~s(err="$1"; shift; exec git "$@" < "$0" 2> "$err")

    try do
      case System.cmd("sh", ["-c", script, input, errors | args], cd: dir, env: env(home)) do
        {out, 0} ->
          out

        {_out, status} ->
          raise "git #{Enum.join(args, " ")} exited #{status}: #{File.read!(errors)}"
      end
    after
      File.rm(errors)
    end
  end
end
