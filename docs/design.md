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
- Tigris, "objgit" (https://www.tigrisdata.com/blog/objgit/) and its follow-up on
  packfiles (https://www.tigrisdata.com/blog/objgit-packfiles/): Git's native layout
  over a bucket costs a round trip per object or per pack, so they moved to one pack
  and one index per push, whole-pack downloads and fewer listings. Taken: the lesson
  that request count, not bytes, decides clone time, so pushes are stored as one pack
  and its index, and nothing is ever listed, renamed or HEAD-requested on a request's
  path. Not taken: their custom pack and index format with zstd; git_server keeps Git's
  own pack and idx formats, so `git verify-pack` checks them. Their packs accumulate
  forever.
- Enroute, "Everyone is doing Git on S3 wrong"
  (https://enroute.sh/blog/everyone-is-doing-git-on-s3-wrong): immutable layers built
  without locks, ordered only by compare-and-swap on the refs a push moves, and merged
  roughly geometrically by copying bytes without recompressing. Taken: merging packs by
  raw copy, geometrically, if git_server compacts. Not taken: rewriting packs as they
  arrive; git_server stores a push's pack as the client sent it.

None of them deletes old packs safely. Tigris keeps everything, Enroute lists garbage
collection as unfinished, Cursor's post doesn't cover it, and walgit keeps retired packs
forever by design, for downloads already in flight. A naive deletion races a client
that re-uploads identical bytes under the same content name just before its push
publishes, so git_server deletes nothing until a design whose safety doesn't depend on
time has been reviewed.
