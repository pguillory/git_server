# git_server: agent instructions

This repository is public, and all work on it is done in public. Never put internal or
proprietary information in code, docs, commit messages or test data: no secrets or
credentials, no account IDs, no bucket names other than placeholders, no hostnames, no
internal project, agent or session names, and no personal data. Test data is synthetic.
Notes about a particular deployment belong with that deployment, not here.

Markdown style: do not use `**` to highlight list items. Write `1. First thing: text`
instead.

## Product

git_server is an Elixir library that serves Git repositories over Git's smart HTTP
protocol (protocol v2 for fetch, v0 receive-pack for push) as a Plug, keeping every
repository in an S3-compatible bucket. The host application mounts `GitServer.Plug`,
supplies the store configuration and an `authorize` callback, and holds every secret.

## Development

- Elixir 1.19 on OTP 28. Run `bin/install-git-hooks` once per clone; the hook runs
  `bin/pre-commit` (format check, warnings-as-errors compile, the test suite).
- There is no hosted CI. The pre-commit hook is the gate.
- Tests drive the real `git` client against the Plug served by Bandit on 127.0.0.1,
  and a real S3 API (MinIO on loopback via `bin/test-s3-local`, or a real bucket).
  There is no fake S3 module. Git runs in an isolated environment (temporary `HOME`,
  no system or global config, no credential helper, no terminal prompt), so a test
  can never touch a developer's keychain or prompt.
- Keep tests simple, fast and single-layer, with real collaborators. A passing run
  prints only dots: no `capture_log` silencing, and an error log means a bug.
- Anything a test or tool serves binds to 127.0.0.1 only.
- Generic mechanisms belong in generic layers: conditional writes live in the store,
  not in the refs code.
- Never log credentials, Authorization headers, or S3 response bodies and headers.
