# Design references

Other designs that keep Git in object storage, and what git_server took from each or
chose not to. They share one shape: immutable pack files in the bucket, and one small
object, written with a conditional PUT, that decides what is visible. git_server's is
`state` (HEAD, refs and the list of packs).

- Cursor, "Git at any scale" (https://cursor.com/blog/git-at-any-scale): a write-ahead
  log in S3 behind a small index object updated by compare-and-swap, with local disks
  as a warm cache and a push acknowledged only once it is persisted. Taken: the store
  as the only truth, and a push visible only after its conditional write. Not taken:
  replicas holding whole materialized repositories, placement by rendezvous hashing,
  and batching writes; one conditional PUT per push is enough for a small server.
- walgit (https://github.com/tobi/walgit): a manifest updated by conditional write is
  the linearization point, a 412 is the normal sign of contention, and losers re-read,
  re-check every ref and retry with jittered backoff. Taken: exactly that retry loop,
  and caching immutable packs by content on local disk. Not taken: a freshness TTL that
  skips reading the manifest (it costs read-your-writes across servers), group commit
  of concurrent pushes, and a lease so that one instance maintains a repository at a
  time; git_server lets the conditional write decide between racing writers instead.
- Xe Iaso, "I taught a bucket to speak git" (Tigris, June 23, 2026,
  https://www.tigrisdata.com/blog/objgit/, discussed at
  https://news.ycombinator.com/item?id=48661938): a filesystem layer over the bucket
  with go-git, which broke on Git's local-filesystem assumptions. Taken: no filesystem
  emulation at all; git_server speaks the protocol itself and stores each push as one
  pack and its index, so nothing is ever listed, renamed or HEAD-requested on a
  request's path.
- Xe Iaso, "You can run git on object storage if you re-make packfiles" (Tigris,
  September 15, 2026, https://www.tigrisdata.com/blog/objgit-packfiles/, discussed at
  https://news.ycombinator.com/item?id=49730069): a custom pack format native to object
  storage, with a columnar index and fixed-width records for exact HTTP Range requests
  and no client changes. A push went from 8.7 s and 231 requests to 2.2 s and 18.
  Taken: the lesson that request count, not bytes, decides how long a clone or push
  takes. Not taken: the custom format; git_server keeps Git's own pack and idx formats,
  so `git verify-pack` checks them, and downloads whole packs rather than ranges. Their
  packs accumulate forever.
- Xe Iaso, the memory follow-up (Tigris, https://www.tigrisdata.com/blog/objgit-ram/):
  a compact, immutable sorted index, about 390 down to 60 bytes per object, and a push
  indexed by objgit itself instead of staged in a scratch repository. Taken: the same
  shape, already: git_server indexes a push itself, streamed to a file, and looks
  objects up in place in Git's own sorted idx files, about 28 bytes per object. Not
  taken: a format of its own for the index.
- Netlify, "How we built Git storage for millions of Netlify projects" (September 2026,
  https://www.netlify.com/blog/how-we-built-git-storage-for-millions/): S3 as the
  source of truth with each pod's disk as an LRU cache of bare repositories driven by
  the git binary, and refs as small records each updated by conditional write. Taken:
  never reporting success before the push is durable, and a ref never ahead of its
  objects. Not taken: a git binary and local repository on the server, and per-ref
  conditional writes; one `state` object holds every ref, so a push of several refs
  lands or fails as a whole. Their side-band progress during a slow push is a good
  idea git_server doesn't have yet.
- Enroute, "Everyone is doing Git on S3 wrong"
  (https://enroute.sh/blog/everyone-is-doing-git-on-s3-wrong): immutable layers built
  without locks, ordered only by compare-and-swap on the refs a push moves, and merged
  roughly geometrically by copying bytes without recompressing. Taken: merging packs by
  raw copy, geometrically, if git_server compacts. Not taken: rewriting packs as they
  arrive; git_server stores a push's pack as the client sent it.

None of them deletes old packs safely. Tigris keeps everything, Enroute lists garbage
collection as unfinished, Cursor's and Netlify's posts don't cover it, and walgit keeps retired packs
forever by design, for downloads already in flight. A naive deletion races a client
that re-uploads identical bytes under the same content name just before its push
publishes, so git_server deletes nothing until a design whose safety doesn't depend on
time has been reviewed.
