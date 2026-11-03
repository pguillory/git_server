# git_server

A Git smart HTTP server for Elixir, as a Plug, that keeps every repository in an
S3-compatible bucket (Cloudflare R2, MinIO, or any S3 API with conditional writes).
Clone, fetch, pull and push work with the ordinary `git` client. There is no git
binary on the server, no local repository and no database: the bucket is the whole
state of the service.

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
- `:max_object_bytes`: the largest object, inflated. Default 50 MB.
- `:max_request_bytes`: the largest upload-pack request body, raw and inflated. Default
  10 MB.
- `:max_command_bytes`: the largest command section of a push. Default 1 MB.
- `:push_deadline_ms`: how long a push keeps retrying while other pushes to the same
  repository win the race. Default 15 seconds.
- `:before_update`: a function that checks a push before it changes anything. See below.
- `:before_update_timeout_ms`: how long one call of `:before_update` may run before the
  push is refused. Default 30 seconds.

Give them directly as the Plug's options, or as `config:` naming a function (`{module,
function, args}` or a zero-arity function) that returns them on each request.

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
library holds no secret and never logs credentials. If `authorize` raises, throws, exits
or returns anything else, the request gets a 500 and the server log gets only the kind
of failure and a stacktrace without arguments.

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

## Storage

Everything for a repository is under `<prefix><repo>.git/`:

```text
state                  HEAD, refs and the list of packs: one small text object
packs/<checksum>.pack  a pack as the client pushed it, immutable
packs/<checksum>.idx   its index in git's own idx v2 format, immutable
```

A push writes at most these three objects, however many git objects it holds. Listing
refs reads only `state`. A fetch or a push also downloads every listed pack and index to
temporary files, deleted when the request ends, so it costs about 1 + 2 × packs GETs.
Nothing compacts packs or caches them yet.

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
   until the deadline, when it is rejected with `failed to update ref`. Pushes to
   different branches all land. Of two pushes to one branch from one base, one lands and
   the other is rejected with `fetch first`, so no update is ever lost.
4. A fetch reads one `state`, and every pack it lists was fully written first, so a clone
   racing pushes is always whole. This relies on the bucket being strongly consistent
   for read after write, as R2 and MinIO are.
5. A push never deletes anything, not even when rejected. Deleting a branch only removes
   the ref.

These rest on the bucket's conditional writes being atomic. Tests cover them on MinIO,
including two writers racing for one key.

The server does not refuse a forced push: a client's `--force` replaces the branch. Use
`authorize` to limit who may write, or `:before_update` to refuse rewrites.

A client quirk to know about: after someone force-pushes over a commit you had pushed,
`git pull --rebase` silently drops that commit, while a plain merge pull keeps both
changes.

## Not supported

- SSH, `git://` and dumb HTTP. Smart HTTP only.
- Fetching with protocol v0 or v1. Git has defaulted to v2 since 2.26 (2020); older
  clients get a message saying so.
- Shallow clones (`--depth`), partial clones (`--filter`) and bundle URIs.
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
