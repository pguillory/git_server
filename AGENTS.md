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

## Modules

- `GitServer.Plug`: routing, request-time config (`GitServer.Config`), HTTP Basic
  credentials and the host's `authorize` callback, the upload-pack advertisement, and
  dispatch of upload-pack (v2) and receive-pack (v0) requests. A failing `authorize`
  is caught and refused with a 500. `GitServer.HTTP`: the responses the Plug and the
  protocol modules send (advertisements, results, text errors).
- `GitServer.Failure`: a host callback's failure described for the log with nothing
  it carries (no message, value or arguments). `GitServer.Worker`: runs a function in
  an unlinked process, killed on timeout or when the caller dies.
- `GitServer.UploadPack`: the v2 commands, `ls-refs` and `fetch`: negotiation, the want
  check, and the pack streamed on side-band 1. `GitServer.ObjectWalk`: reachability
  over an object database.
- `GitServer.PktLine`: pkt-line and side-band framing. `GitServer.Body`: capped,
  gzip-aware request body reading, whole or streamed to a file.
- `GitServer.RepoName`: repository names from the request path.
- `GitServer.State`: the text codec of a repository's `state` object (HEAD, refs,
  pack list). `GitServer.Repository`: the store layout, state reads, the conditional
  state write, `update` (the retry loop every state writer goes through: compute,
  write conditionally, refresh and compute again on a lost race, up to a deadline),
  and snapshots (the listed packs downloaded to a temp directory).
- `GitServer.ReceivePack`: push, the receive-pack advertisement and request side:
  reading and parsing the commands, the probe, the pack streamed to a file, and
  report-status. `GitServer.ReceivePack.Update`: the push itself: the pack indexed and
  checked against the state, the pack stored, then the state published through
  `Repository.update`, with the host's `before_update` check run in its own process
  on every attempt. `GitServer.Push`: what
  that check sees, and reading files at a commit (`list_files`, `read_file`).
  `GitServer.RefName`: the ref names a push may update.
- `GitServer.Store`: the store behaviour (`get`, `get_file`, `put`, `put_file` with a
  condition, `delete`, `list`). `GitServer.Store.S3` is its implementation.

## Tests

Start MinIO on loopback once with `bin/test-s3-local start` (it writes
`tmp/test-s3.env`, which the tests read), then `mix test`. `bin/test-s3-local stop`
stops it. To use a real bucket instead, set `GIT_SERVER_TEST_S3_ENDPOINT`, `_BUCKET`,
`_REGION`, `_ACCESS_KEY_ID` and `_SECRET_ACCESS_KEY`. Each run works under a fresh
`test-<random>/` prefix and deletes it at the end.

`bin/demo` runs the demo server (`dev/demo.exs`) against MinIO on loopback, or against
the bucket in a settings file of `GIT_SERVER_TEST_S3_*` lines; the README has the
sequence to try it with.

Before every push, run `bin/hygiene-scan` (optionally with a private term list kept
outside the repository) and read every hit.
