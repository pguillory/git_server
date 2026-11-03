# git_server

A Git smart HTTP server for Elixir, as a Plug, that keeps every repository in an
S3-compatible bucket (Cloudflare R2, MinIO, or any S3 API with conditional writes).
Clone, fetch, pull and push work with the ordinary `git` client, shallow clones
included. There is no git binary on the server, no local repository and no database:
the bucket is the whole state of the service.

## Trying it

`bin/demo` serves repositories from MinIO on loopback (`brew install minio`), which it
starts if needed. It needs Elixir 1.19, curl, openssl and python3.

```sh
GIT_SERVER_DEMO_PORT=4100 GIT_SERVER_DEMO_PASSWORD=demo bin/demo
```

Then, in another terminal:

```sh
cd /tmp && rm -rf demo-a demo-b
git clone -c credential.helper= http://demo:demo@127.0.0.1:4100/hello demo-a
cd demo-a && echo "hi $(date)" > README && git add README && git commit -m first && git push -u origin main
cd /tmp && git clone -c credential.helper= http://demo:demo@127.0.0.1:4100/hello demo-b && cat demo-b/README
cd demo-b && echo more >> README && git commit -am second && git push
cd /tmp/demo-a && git pull && cat README
```

The `-c credential.helper=` keeps a throwaway password out of any credential store, and
the URL leaves it in plain text in each clone's `.git/config`, so this is for the demo
only. With a password-less URL, git asks once and its credential helper remembers.
`bin/test-s3-local stop` stops MinIO and deletes its data.

To use a real bucket, put its settings in a file outside the repository and pass it
with `bin/demo <file>`. The file is sourced by the shell, so quote any value with
special characters:

```sh
GIT_SERVER_TEST_S3_ENDPOINT=https://...
GIT_SERVER_TEST_S3_BUCKET=...
GIT_SERVER_TEST_S3_REGION=...
GIT_SERVER_TEST_S3_ACCESS_KEY_ID=...
GIT_SERVER_TEST_S3_SECRET_ACCESS_KEY=...
```

The demo keeps its repositories under the prefix `demo/`, listens on 127.0.0.1 only,
and accepts any username with the password. See `dev/demo.exs`.

## Using it

Add `{:git_server, github: "pguillory/git_server"}` to your dependencies, then mount the
Plug. It reads request bodies itself, so nothing ahead of it may consume them:

```elixir
# In a Plug.Router
forward "/git", to: GitServer.Plug, init_opts: [config: {MyApp.Git, :config, []}]

# In a Phoenix router
forward "/git", GitServer.Plug, config: {MyApp.Git, :config, []}
```

```elixir
defmodule MyApp.Git do
  # Called on every request, so no secret is compiled into the router.
  def config do
    {:ok, store} =
      GitServer.Store.S3.new(
        endpoint: System.fetch_env!("S3_ENDPOINT"),
        bucket: System.fetch_env!("S3_BUCKET"),
        region: System.fetch_env!("S3_REGION"),
        access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
        secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY"),
        prefix: "git/"
      )

    [store: store, authorize: &authorize/1]
  end

  defp authorize(%{repo: repo, access: access, credentials: {user, password}}) do
    cond do
      not MyApp.Accounts.valid?(user, password) -> :unauthorized
      MyApp.Accounts.can?(user, access, repo) -> :ok
      true -> :forbidden
    end
  end

  defp authorize(_request), do: :unauthorized
end
```

Serve it over HTTPS: git sends the password with every authenticated request. The host
brings its own Plug server; Bandit is only a development dependency here. A
`Plug.Parsers` ahead of the router needs `pass: ["*/*"]` so it leaves git's request
bodies unread.

### Options

- `:store` (required): from `GitServer.Store.S3.new/1`, or your own implementation of
  the `GitServer.Store` behaviour.
- `:authorize` (required): see below.
- `:temp_dir`: where request files go. Default `System.tmp_dir!()`.
- `:max_pack_bytes`: the largest pack a push may send. Default 100 MB.
- `:max_objects`: the most objects in a pushed pack. Default 100,000.
- `:max_object_bytes`: the largest object, inflated, in a push or a stored pack. Default
  50 MB.
- `:max_delta_depth`: the longest delta chain, in a push or a stored pack. Default 100.
- `:max_fetch_work_bytes`: how much work one fetch may spend resolving the delta bases
  under the objects it reads, in bytes inflated and produced, beyond an allowance of
  twice `:max_delta_depth` times the bytes it reads. The objects themselves never
  count. So a history of large files changed many times stays within it, while a pack
  built to make a fetch resolve the same long chains again and again for little output
  doesn't. Default 1 GB.
- `:max_request_bytes`: the largest upload-pack request body, raw and inflated. Default
  10 MB.
- `:max_command_bytes`: the largest command section of a push. Default 1 MB.
- `:push_deadline_ms`: how long a push keeps retrying while other pushes to the same
  repository win the race. Default 15 seconds.
- `:before_update`: a function that checks a push before it changes anything. See below.
- `:before_update_timeout_ms`: how long one call of `:before_update` may run before the
  push is refused. Default 30 seconds.
- `:after_update`: a function called after a push lands. See below.
- `:after_update_timeout_ms`: how long one call of `:after_update` may run before it is
  killed. Default 30 seconds.
- `:download_concurrency`: how many store downloads one request runs at once, a positive
  integer. A fetch or push downloads every pack and idx the repository lists. Each
  download holds a store connection, and the S3 store's pool holds 50 per endpoint, a
  request waiting at most 5 s for one, so this times the number of requests at once
  should stay under 50. Default 8.
- `:pack_cache_dir`: a directory for a local cache of stored packs, so a fetch or push
  downloads only the packs it hasn't seen. Worth it for a remote store; see "Storage"
  below. Default none (no cache).
- `:pack_cache_bytes`: the size the pack cache is kept under. Default 1 GB.

The pack size and object count limit what a push may send; a pack already stored is
read whatever its size and count.

Give them directly as the Plug's options, or as `config:` naming a function (`{module,
function, args}` or a zero-arity function) that returns them on each request. If that
function raises, throws, exits or returns something other than a keyword list or map,
or the options are wrong, the request gets a 500 and the log says which, without any
option's value or the failure's message: for a failure, its kind, an exception's module
and a stacktrace without arguments.

`GitServer.Store.S3` requires `https` for any endpoint not on this machine.

### The `authorize` function

It's called before any store access with a map:

- `repo`: the repository name from the path, without a trailing `.git`.
- `access`: `:read` for fetches, `:write` for pushes.
- `credentials`: `{username, password}` from HTTP Basic, or `nil` when there are none,
  more than one Authorization header, or a malformed one. Git's first request usually
  has none, so answer `:unauthorized` to make it ask.
- `conn`: the `Plug.Conn`.

It returns `:ok`, `:unauthorized` (401 with a Basic challenge) or `:forbidden` (403). The
library holds no secret, and its own log lines never hold credentials. If `authorize`
raises, throws, exits or returns anything else, the request gets a 500 and the server
log says only which: for a raise, throw or exit, its kind, an exception's module and a
stacktrace without arguments; for a return, not the value.

Rate limiting failed logins is up to `authorize`, which sees the conn (its remote
address, for one).

One thing the library can't control: if a request crashes anywhere else in the Plug
(a bug), or its body times out or is malformed, the HTTP server logs it, and Bandit
attaches the request's original conn, Authorization header included, as `conn` logger
metadata. Logger's default formatter doesn't print it, but a formatter configured to
print all metadata, or an error tracker that captures it, would record the password.
Leave `conn` out of the metadata your log formatter prints, and have your error tracker
drop or scrub the Authorization header.

There is no create step. A repository with nothing in the bucket is an empty one, so
`authorize` decides which names may exist. A name is one or more `/`-separated segments
of letters, digits, `.`, `_` and `-`, at most 200 bytes in all. One trailing `.git` in the
URL is dropped, so `notes` and `notes.git` are the same repository. After that, no
segment may start with `.` or end in `.git`. Anything else is 404, including any path
with percent-encoding, and that happens before `authorize` is called.

### Checking a push

`:before_update` sees a push after the server's own checks pass and before anything
is published, and can refuse it with a message git shows the user:

```elixir
before_update: fn push ->
  errors =
    for %{new: new} <- push.updates, new != nil do
      case GitServer.Push.read_file(push, new, "config.toml") do
        {:ok, text} -> MyApp.Config.errors(text)
        :error -> ["config.toml is missing"]
        {:error, reason} -> ["config.toml can't be read: #{reason}"]
      end
    end
    |> List.flatten()

  if errors == [], do: :ok, else: {:reject, Enum.join(errors, "\n")}
end
```

It gets a `GitServer.Push`:

- `repo`: the repository name.
- `conn`: the `Plug.Conn`, to read (for example assigns your own plugs set), not to send on.
- `refs`: the repository's refs before the push, `%{name => id}`.
- `updates`: what lands if it approves, in the client's order:
  `[%{ref: name, old: id | nil, new: id | nil}]`. `old: nil` creates a ref and `new: nil`
  deletes one. Ids are hex. Only updates that passed the server's checks are listed.

During the call, `GitServer.Push.list_files(push, id)` lists every file in the tree at a
commit (or an annotated tag of one), and `GitServer.Push.read_file(push, id, path)` reads
one, at a ref's old tip or its new one. Each object read is capped by `:max_object_bytes`,
and a listing by entries and path bytes, so a hostile push can't make them expensive. A
tree with an entry name that could check out somewhere else (`..`, `.git` or `.GIT`, a
`/`, two names differing only in case) is an error, and `read_file` doesn't follow
symlinks (reading through one is an error), so a path that reads is the file a clone
would have there, short of rarer file-system aliases.

It returns `:ok`, or `{:reject, message}` to refuse the whole push. Git then prints the
message as `remote:` lines, as given (plus a final newline if it lacks one) and of any
length, and reports every ref it was shown as
`! [remote rejected] main -> main (declined)`. Nothing is published. The message isn't
escaped, so take care quoting pushed file names in it.

It fails closed: if it raises, throws, exits, returns anything else or runs past
`:before_update_timeout_ms`, the push is refused with `push check failed` and the error is
logged without anything from the push or from the exception's message.

It may be called more than once for one push. When the state write loses a race to
another push, the server checks again against the new state and calls the function again,
and the write only succeeds on exactly the state the latest call saw. So a push never lands
on a repository its check didn't see, and an approval doesn't mean the push landed. A push
refused after a lost race may leave its pack stored but unlisted, which is harmless.

### After a push

`:after_update` is called once for each push that landed, after git has its report, for
webhooks, CI triggers and notifications. It gets a map:

- `repo`: the repository name.
- `conn`: the `Plug.Conn`, to read (its response has been sent).
- `updates`: what landed, in the client's order, as `before_update` sees them:
  `[%{ref: name, old: id | nil, new: id | nil}]`. Without `--atomic`, a push can land some
  refs and not others; only those that landed are listed.

It's never called for a push that changed nothing (refused, declined, stale, or failed).
It runs in a process of its own and its result is ignored. If it raises, throws, exits or
runs past `:after_update_timeout_ms`, the server logs which, as for `before_update`, and
the push, already landed, is unaffected. The request's connection waits for it, so hand
slow work to a job queue.

## When something goes wrong

What `git` prints for each failure (the tests check these lines, against real git for
all but the `:max_request_bytes` row). Git shows a server's message itself only on its first
request; after that, an HTTP error comes out as `error: RPC failed; HTTP 500` and
nothing more, so failures after it are answered inside the protocol. The exceptions,
still plain HTTP errors, are requests git itself doesn't send (malformed or truncated
ones), and a `config` or `authorize` that fails or refuses only on a later request.

| What happened | What `git` prints |
| --- | --- |
| Wrong password | `remote: Authentication failed: wrong or missing username or password`, then `fatal: Authentication failed for '<url>'` |
| No credentials, and git can't prompt | `fatal: could not read Username for '<url>': terminal prompts disabled` (git's own) |
| `authorize` says `:forbidden` | `remote: Access denied: you can't read this repository, or it doesn't exist` (or `push to`), then `The requested URL returned error: 403`. It never says whether the repository exists. |
| A name that can't be a repository | `remote: Not found`, then `fatal: repository '<url>' not found` |
| Fetching with protocol v0 or v1 | `remote: git_server needs Git protocol version 2 to fetch (git 2.26 or later, protocol.version=2)` |
| The host's `config` or `authorize` fails | `remote: Server error`, then `The requested URL returned error: 500`; the server log says what failed |
| Storage fails on a push's first request | `remote: the server's storage failed; try again later`, then `The requested URL returned error: 500` |
| Storage fails listing refs or fetching | `fatal: remote error: the server's storage failed; try again later` |
| Storage fails during a push | `! [remote rejected] main -> main (storage failed, try again later)` |
| A push over `:max_pack_bytes` | `error: remote unpack failed: pack too large (limit 100 MB)` and `! [remote rejected] main -> main (unpacker error)` |
| An object over `:max_object_bytes` | `error: remote unpack failed: object too large (limit 50 MB)` |
| A push over `:max_objects` | `error: remote unpack failed: too many objects in pack (limit 100000)` |
| A push that keeps losing the race until `:push_deadline_ms` | `! [remote rejected] main -> main (failed to update ref, too many pushes at once)` |
| `before_update` refuses | its message as `remote:` lines, then `! [remote rejected] main -> main (declined)` |
| `before_update` fails or times out | `remote: The server could not check this push.`, then `(push check failed)` |
| A fetch of an object no ref reaches | `fatal: remote error: upload-pack: not our ref <id>` |
| A fetch over `:max_fetch_work_bytes` | `remote: git_server: too much work resolving delta bases`, then `fatal: early EOF` |
| A push whose ref commands are over `:max_command_bytes` (thousands of refs at once) | `error: remote unpack failed: too many ref commands (limit 1 MB)`, each ref then `(remote failed to report status)` |
| A pushed delta chain over `:max_delta_depth` | `error: remote unpack failed: delta chain too deep (limit 100)` |
| An upload-pack request over `:max_request_bytes` | `fatal: remote error: request too large (limit 10 MB)` |
| `git clone --shallow-exclude` (or `fetch`) | `fatal: remote error: deepen-not (--shallow-exclude) is not supported` |
| `--shallow-since` later than every commit | `fatal: remote error: no commits selected for shallow requests` (git's own message) |

The server log keeps the reason for every storage failure; the client never sees store
details. Limits show their configured values.

A push over `:max_pack_bytes` is read to the end and dropped, so git gets its report
rather than a broken pipe, as long as the push is within four times the limit and
arrives within `:push_deadline_ms`. Past either, the server replies and closes the
connection, and git may print `RPC failed` or `Everything up-to-date` beside the
report. Nothing lands either way.

## Storage

Everything for a repository is under `<prefix><repo>.git/`:

```text
state                  HEAD, refs and the list of packs: one small text object
packs/<checksum>.pack  a pack as the client pushed it, immutable
packs/<checksum>.idx   its index in git's own idx v2 format, immutable
```

A push writes at most these three objects, however many git objects it holds. Listing
refs reads only `state`. A fetch or a push also downloads every listed pack and index to
temporary files, deleted when the request ends, so without the pack cache it costs about
1 + 2 × packs GETs, `:download_concurrency` at a time. Nothing compacts packs yet.

With `:pack_cache_dir`, downloaded packs and indexes are also kept in that directory, so
a request downloads only packs it hasn't seen and a warm fetch reads only `state`. A
pack's key names its checksum and a stored pack never changes, so an entry is never
stale; each one is checked (the pack's SHA-1 against its trailer and name, the index's
own checksum, and the two against each other) before it goes in. The directory is made
private to this user if it doesn't exist, must be private to it and hold nothing else,
may be shared by servers running as that user, and has its least recently used entries
removed once it passes `:pack_cache_bytes`. If it can't be used, requests log that and
go on without it. Requests take entries by hard link, so the
cache works best on the same file system as `:temp_dir` (otherwise each is copied).

The cache pays off when the store is remote: on R2, a warm clone of a repository with
100 pushes took 0.6 s against 5 s without it. Its own cost is a few file-system calls per
pack (links and renames, about 1 ms per pack warm and 3 ms cold on a Mac), so for a store
on the same machine, such as MinIO on loopback, it makes clones slower, not faster.

### Guarantees

The store must support conditional PUT (`If-Match` and `If-None-Match: *`).

1. Every object in a listed pack has everything it refers to in the listed packs, and
   every ref names an object in them. A push checks this for each new object before
   anything is stored.
2. A push writes its pack and index first and `state` last, so a crash at any point
   leaves readers with the old repository whole. An interrupted push leaves at worst an
   unlisted pack, which is harmless garbage. Nothing deletes garbage yet.
3. `state` is only ever replaced conditionally on the version the push checked against.
   A push that loses the race re-reads `state`, checks its commands again and retries,
   until the deadline, when it is rejected with `failed to update ref, too many pushes
   at once`. Pushes to
   different branches all land. Of two pushes to one branch from one base, one lands and
   the other is rejected with `fetch first`, so no update is ever lost.
4. A fetch reads one `state`, and every pack it lists was fully written first, so a clone
   racing pushes is always whole. This relies on the bucket being strongly consistent
   for read after write, as R2 and MinIO are.
5. A push never deletes anything, not even when rejected. Deleting a branch only removes
   the ref.

These rest on the bucket's conditional writes being atomic. Tests cover them on MinIO,
including two writers racing for one key.

[docs/design.md](docs/design.md) compares this design with other Git-on-object-storage
designs and says what it took from each.

The server does not refuse a forced push: a client's `--force` replaces the branch. Use
`authorize` to limit who may write, or `:before_update` to refuse rewrites.

A client quirk to know about: after someone force-pushes over a commit you had pushed,
`git pull --rebase` silently drops that commit, while a plain merge pull keeps both
changes.

## Not supported

- SSH, `git://` and dumb HTTP. Smart HTTP only.
- Fetching with protocol v0 or v1. Git has defaulted to v2 since 2.26 (2020); older
  clients get a message saying so.
- `--shallow-exclude`, partial clones (`--filter`) and bundle URIs. Other shallow
  clones and fetches work (`--depth`, `--deepen`, `--shallow-since`, `--unshallow`).
- SHA-256 repositories.
- Push options, signed pushes and thin packs (the server tells clients not to send them).
- Pack compaction and garbage collection of unlisted packs.

## Tests

Tests drive the real `git` client against the Plug on loopback and a real S3 API, with
git isolated from your configuration so they can't reach a credential store or prompt.

```sh
bin/test-s3-local start   # MinIO on 127.0.0.1, settings in tmp/test-s3.env
mix test
bin/test-s3-local stop
```

To use a real bucket instead, set `GIT_SERVER_TEST_S3_ENDPOINT`, `_BUCKET`, `_REGION`,
`_ACCESS_KEY_ID` and `_SECRET_ACCESS_KEY`. Each run works under a fresh `test-<random>/`
prefix and deletes it at the end.

`bin/install-git-hooks` installs the pre-commit hook: format check, warnings-as-errors
compile and the tests. There is no hosted CI, so the hook is the gate.

## License

MIT. See [LICENSE](LICENSE).
