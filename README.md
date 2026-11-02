# git_server

A Git smart HTTP server for Elixir, as a Plug, that keeps every repository in an
S3-compatible bucket (Cloudflare R2, MinIO, or any S3 API). Clone, fetch, pull and
push work with the ordinary `git` client.

Work in progress: fetching objects is not implemented yet.

## Trying it

`dev/demo.exs` serves repositories from a bucket on `http://127.0.0.1:4000`:

```sh
export GIT_SERVER_S3_ENDPOINT=... GIT_SERVER_S3_BUCKET=... GIT_SERVER_S3_REGION=... \
  GIT_SERVER_S3_ACCESS_KEY_ID=... GIT_SERVER_S3_SECRET_ACCESS_KEY=... GIT_SERVER_S3_PREFIX=demo/
mix run --no-halt dev/demo.exs
```

## Tests

`bin/test-s3-local start` runs MinIO on loopback for the tests, then `mix test`.

## License

MIT. See [LICENSE](LICENSE).
