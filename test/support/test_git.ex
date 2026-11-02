defmodule GitServer.TestGit do
  @moduledoc """
  Runs the real `git` client, isolated from the developer's setup: a temporary
  `HOME`, no system config, a global config file of our own, no credential helper,
  no terminal prompt or askpass program, and every other `GIT_*` variable unset (a
  pre-commit hook runs the tests with `GIT_DIR` and `GIT_INDEX_FILE` set).
  Credentials go in URLs. `setup!/0` checks once that no credential helper is
  configured, so a test can never reach a keychain or raise a prompt.
  """

  @doc "Creates the isolated home and config, and checks that no credential helper remains."
  def setup! do
    home =
      Path.join(
        System.tmp_dir!(),
        "git_server-test-home-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    File.rm_rf!(home)
    File.mkdir_p!(home)
    config = Path.join(home, "gitconfig")

    File.write!(config, """
    [user]
    \tname = Test User
    \temail = test@example.com
    [init]
    \tdefaultBranch = main
    [protocol]
    \tversion = 2
    """)

    :persistent_term.put(__MODULE__, %{home: home, config: config})
    System.at_exit(fn _status -> File.rm_rf(home) end)

    # The only entry may be our own empty `-c credential.helper=`, which resets the list.
    case git(["config", "--show-origin", "--get-all", "credential.helper"], cd: home) do
      {"command line:\t\n", 0} -> :ok
      {output, status} -> raise "git still has a credential helper (status #{status}): #{output}"
    end
  end

  @doc """
  Runs `git args` and returns `{output, exit_status}`, stdout and stderr together.
  Options: `:cd` (default the isolated home), `:env` (extra variables).
  """
  def git(args, opts \\ []) do
    %{home: home, config: config} = :persistent_term.get(__MODULE__)

    inherited =
      for {name, _value} <- System.get_env(), String.starts_with?(name, "GIT_"), do: {name, nil}

    env =
      inherited ++
        [
          {"HOME", home},
          {"XDG_CONFIG_HOME", home},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", config},
          {"GIT_TERMINAL_PROMPT", "0"},
          {"GIT_ASKPASS", nil},
          {"SSH_ASKPASS", nil},
        ] ++ Keyword.get(opts, :env, [])

    System.cmd("git", ["-c", "credential.helper=" | args],
      cd: Keyword.get(opts, :cd, home),
      env: env,
      stderr_to_stdout: true
    )
  end
end
