GitServer.TestStore.setup!()
GitServer.TestGit.setup!()

# Not in ExUnit.after_suite, which runs after every pass of --repeat-until-failure.
System.at_exit(fn _status -> GitServer.TestStore.cleanup() end)

# Long race runs: `mix test --include slow`.
ExUnit.start(exclude: [:slow])
