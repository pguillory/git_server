defmodule GitServer.ReceivePackRequestTest do
  # Push requests built by hand, for what real git checks before it sends: stale and
  # atomic commands, duplicates, malformed packs. Packs come from `git pack-objects`
  # or `GitServer.PackBuilder`.
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]
  import GitServer.LocalGit
  alias GitServer.{ObjectId, PackBuilder, PktLine, Repository, State}

  @moduletag :tmp_dir
  @zero String.duplicate("0", 40)
  @repo "repo"

  setup %{tmp_dir: tmp_dir} do
    store = GitServer.TestStore.fresh()
    opts = GitServer.Plug.init(store: store, authorize: fn _ -> :ok end, temp_dir: tmp_dir)

    # Two commits, a then b on top of it.
    home = Path.join(tmp_dir, "home")
    local = Path.join(tmp_dir, "local")
    File.mkdir_p!(local)
    File.mkdir_p!(home)
    git!(home, local, ["init", "-q"])
    File.write!(Path.join(local, "f"), "one\n")
    git!(home, local, ["add", "f"])
    git!(home, local, ["commit", "-q", "-m", "a"])
    File.write!(Path.join(local, "f"), "two\n")
    git!(home, local, ["commit", "-q", "-am", "b"])
    a = String.trim(git!(home, local, ["rev-parse", "HEAD~"]))
    b = String.trim(git!(home, local, ["rev-parse", "HEAD"]))

    %{opts: opts, store: store, home: home, local: local, a: a, b: b}
  end

  # A pack of the objects reachable from the `revs` (`id` or `^id` lines).
  defp pack!(ctx, revs) do
    input = Path.join(ctx.tmp_dir, "revs-#{System.unique_integer([:positive])}")
    File.write!(input, Enum.map(revs, &(&1 <> "\n")))
    git!(ctx.home, ctx.local, ["pack-objects", "-q", "--revs", "--stdout"], input: input)
  end

  defp push(ctx, commands, pack, capabilities \\ "report-status") do
    [first | rest] = Enum.map(commands, fn {old, new, ref} -> "#{old} #{new} #{ref}" end)

    body =
      IO.iodata_to_binary([
        PktLine.encode("#{first}\0#{capabilities}\n"),
        Enum.map(rest, &PktLine.encode(&1 <> "\n")),
        PktLine.flush(),
        pack,
      ])

    post(ctx, body)
  end

  defp post(ctx, body) do
    conn(:post, "/#{@repo}/git-receive-pack", body)
    |> put_req_header("content-type", "application/x-git-receive-pack-request")
    |> GitServer.Plug.call(ctx.opts)
  end

  defp report(conn) do
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/x-git-receive-pack-result"]
    {:ok, packets} = PktLine.decode(conn.resp_body)
    assert List.last(packets) == :flush
    packets |> Enum.drop(-1) |> Enum.map(&PktLine.chomp/1)
  end

  defp state(ctx) do
    {:ok, state, _etag} = Repository.read_state(ctx.store, @repo)
    state
  end

  # main at a, in one pack.
  defp seed(ctx) do
    assert report(push(ctx, [{@zero, ctx.a, "refs/heads/main"}], pack!(ctx, [ctx.a]))) ==
             ["unpack ok", "ok refs/heads/main"]

    state(ctx)
  end

  test "a stale old is rejected and the state is unchanged", ctx do
    before = seed(ctx)
    conn = push(ctx, [{@zero, ctx.b, "refs/heads/main"}], pack!(ctx, [ctx.b, "^" <> ctx.a]))
    assert report(conn) == ["unpack ok", "ng refs/heads/main fetch first"]
    assert state(ctx) == before
  end

  test "without atomic the valid commands apply", ctx do
    seed(ctx)

    commands = [{ctx.a, ctx.b, "refs/heads/main"}, {ctx.b, ctx.b, "refs/heads/other"}]
    conn = push(ctx, commands, pack!(ctx, [ctx.b, "^" <> ctx.a]))

    assert report(conn) == [
             "unpack ok",
             "ok refs/heads/main",
             "ng refs/heads/other fetch first",
           ]

    assert %{refs: %{"refs/heads/main" => b}, packs: [_, _]} = state(ctx)
    assert b == ctx.b
  end

  test "with atomic nothing applies", ctx do
    before = seed(ctx)

    commands = [{ctx.a, ctx.b, "refs/heads/main"}, {ctx.b, ctx.b, "refs/heads/other"}]
    conn = push(ctx, commands, pack!(ctx, [ctx.b, "^" <> ctx.a]), "report-status atomic")

    assert report(conn) == [
             "unpack ok",
             "ng refs/heads/main atomic push failure",
             "ng refs/heads/other fetch first",
           ]

    assert state(ctx) == before
  end

  # Another push's state lands between this push's check and its state write.
  defp race(ctx, competitor) do
    store =
      GitServer.RacingStore.wrap(ctx.store, fn ->
        {:ok, state, etag} = Repository.read_state(ctx.store, @repo)
        {:ok, _} = Repository.put_state(ctx.store, @repo, competitor.(state), etag)
      end)

    %{ctx | opts: Keyword.put(ctx.opts, :store, store)}
  end

  test "a push that loses the state race is checked again and keeps the winner's update",
       ctx do
    seed(ctx)
    raced = race(ctx, &%{&1 | refs: Map.put(&1.refs, "refs/heads/other", ctx.a)})
    conn = push(raced, [{ctx.a, ctx.b, "refs/heads/main"}], pack!(ctx, [ctx.b, "^" <> ctx.a]))
    assert report(conn) == ["unpack ok", "ok refs/heads/main"]

    assert %{refs: refs, packs: [_, _]} = state(ctx)
    assert refs == %{"refs/heads/main" => ctx.b, "refs/heads/other" => ctx.a}
  end

  test "a push that loses the state race to an update of its ref is told to fetch first",
       ctx do
    before = seed(ctx)
    tags = Map.put(before.refs, "refs/tags/t", ctx.a)
    raced = race(ctx, &%{&1 | refs: tags})
    conn = push(raced, [{@zero, ctx.a, "refs/tags/t"}], pack!(ctx, [ctx.a, "^" <> ctx.a]))
    assert report(conn) == ["unpack ok", "ng refs/tags/t fetch first"]
    assert state(ctx).refs == tags
  end

  test "a new ref beside a ref that is its directory, or inside it, is rejected", ctx do
    seed(ctx)

    commands = [
      {@zero, ctx.a, "refs/heads/main/sub"},
      {@zero, ctx.a, "refs/heads/x"},
      {@zero, ctx.a, "refs/heads/x/y"},
      {@zero, ctx.a, "refs/heads"},
    ]

    assert report(push(ctx, commands, pack!(ctx, [ctx.a, "^" <> ctx.a]))) == [
             "unpack ok",
             "ng refs/heads/main/sub ref name conflicts with an existing ref",
             "ng refs/heads/x ref name conflicts with an existing ref",
             "ng refs/heads/x/y ref name conflicts with an existing ref",
             "ng refs/heads ref name conflicts with an existing ref",
           ]

    assert Map.keys(state(ctx).refs) == ["refs/heads/main"]
  end

  test "duplicate commands for one ref are rejected", ctx do
    commands = [
      {@zero, ctx.a, "refs/heads/main"},
      {@zero, ctx.a, "refs/heads/x"},
      {@zero, ctx.a, "refs/heads/main"},
    ]

    assert report(push(ctx, commands, pack!(ctx, [ctx.a]))) == [
             "unpack ok",
             "ng refs/heads/main duplicate ref command",
             "ok refs/heads/x",
             "ng refs/heads/main duplicate ref command",
           ]

    assert state(ctx).refs == %{"refs/heads/x" => ctx.a}
  end

  test "an all-delete push sends no pack", ctx do
    seed(ctx)
    conn = push(ctx, [{@zero, ctx.a, "refs/heads/topic"}], pack!(ctx, [ctx.a, "^" <> ctx.a]))
    assert report(conn) == ["unpack ok", "ok refs/heads/topic"]

    conn = push(ctx, [{ctx.a, @zero, "refs/heads/topic"}], "")
    assert report(conn) == ["unpack ok", "ok refs/heads/topic"]
    assert state(ctx).refs == %{"refs/heads/main" => ctx.a}
  end

  test "a pack with no objects creates a ref at an existing commit and lists nothing", ctx do
    before = seed(ctx)
    conn = push(ctx, [{@zero, ctx.a, "refs/tags/t"}], pack!(ctx, [ctx.a, "^" <> ctx.a]))
    assert report(conn) == ["unpack ok", "ok refs/tags/t"]
    assert state(ctx) == %{before | refs: Map.put(before.refs, "refs/tags/t", ctx.a)}
  end

  test "the probe, a body of only a flush, changes nothing", ctx do
    conn = post(ctx, "0000")
    assert conn.status == 200
    assert conn.resp_body == ""
    assert Repository.read_state(ctx.store, @repo) == {:ok, State.new(), :absent}
  end

  test "a pack with a referent of the wrong type is rejected", ctx do
    blob = PackBuilder.object(:blob, "data\n")
    commit = PackBuilder.object(:commit, "tree #{ObjectId.to_hex(blob.id)}\n\nbad\n")
    {pack, _} = PackBuilder.build([blob, commit])
    conn = push(ctx, [{@zero, ObjectId.to_hex(commit.id), "refs/heads/main"}], pack)

    assert report(conn) == [
             "unpack #{ObjectId.to_hex(blob.id)} is a blob, not a tree " <>
               "(from #{ObjectId.to_hex(commit.id)})",
             "ng refs/heads/main unpacker error",
           ]

    assert Repository.read_state(ctx.store, @repo) == {:ok, State.new(), :absent}
  end

  # Fetch's object walk trusts a link's declared type, so a commit hidden behind a
  # "blob" link must never get in.
  test "a tree entry or tag calling an existing commit a blob is rejected", ctx do
    seed(ctx)
    {:ok, a} = ObjectId.from_hex(ctx.a)
    tree = PackBuilder.object(:tree, "100644 f\0" <> a)
    commit = PackBuilder.object(:commit, "tree #{ObjectId.to_hex(tree.id)}\n\nhide\n")
    tag = PackBuilder.object(:tag, "object #{ctx.a}\ntype blob\ntag t\n\nhide\n")

    for {entries, ref, id, from} <- [
          {[tree, commit], "refs/heads/hide", commit.id, tree.id},
          {[tag], "refs/tags/hide", tag.id, tag.id},
        ] do
      {pack, _} = PackBuilder.build(entries)
      conn = push(ctx, [{@zero, ObjectId.to_hex(id), ref}], pack)

      assert report(conn) == [
               "unpack #{ctx.a} is a commit, not a blob (from #{ObjectId.to_hex(from)})",
               "ng #{ref} unpacker error",
             ]
    end

    assert Map.keys(state(ctx).refs) == ["refs/heads/main"]
  end

  test "a pack missing a referent is rejected", ctx do
    conn = push(ctx, [{@zero, ctx.b, "refs/heads/main"}], pack!(ctx, [ctx.b, "^" <> ctx.a]))
    assert ["unpack missing commit " <> _, "ng refs/heads/main unpacker error"] = report(conn)
  end

  test "a thin pack is rejected", ctx do
    base = PackBuilder.object(:blob, "base\n")
    id = GitServer.Object.id(:blob, "new\n")
    delta = PackBuilder.ref_delta(id, base.id, PackBuilder.insert_delta(5, "new\n"))
    {pack, _} = PackBuilder.build([delta])
    conn = push(ctx, [{@zero, ObjectId.to_hex(id), "refs/tags/t"}], pack)
    assert report(conn) == ["unpack thin pack not supported", "ng refs/tags/t unpacker error"]
  end

  test "a branch must be a commit, a tag need not be", ctx do
    blob = PackBuilder.object(:blob, "data\n")
    {pack, _} = PackBuilder.build([blob])
    hex = ObjectId.to_hex(blob.id)
    conn = push(ctx, [{@zero, hex, "refs/heads/main"}, {@zero, hex, "refs/tags/t"}], pack)
    assert report(conn) == ["unpack ok", "ng refs/heads/main not a commit", "ok refs/tags/t"]
    assert state(ctx).refs == %{"refs/tags/t" => hex}
  end

  test "invalid ref names are rejected", ctx do
    names = [
      "HEAD",
      "refs/",
      "refs/heads/",
      "refs/heads/a..b",
      "refs/heads/.hidden",
      "refs/heads/a.lock",
      "refs/heads/a.",
      "refs/heads/a@{1}",
      "refs/heads/a//b",
      "refs/heads/a b",
      "refs/heads/a:b",
      "refs/heads/a\\b",
      "refs/heads/a*",
      "refs/heads/" <> String.duplicate("x", 1014),
    ]

    commands = Enum.map(names, &{@zero, ctx.a, &1})

    assert report(push(ctx, commands, pack!(ctx, [ctx.a]))) ==
             ["unpack ok" | Enum.map(names, &"ng #{&1} invalid ref name")]

    assert Repository.read_state(ctx.store, @repo) == {:ok, State.new(), :absent}
  end

  test "a first push with neither main nor master points HEAD at the first branch by name",
       ctx do
    commands = [{@zero, ctx.a, "refs/heads/zeta"}, {@zero, ctx.a, "refs/heads/beta"}]
    assert report(push(ctx, commands, pack!(ctx, [ctx.a]))) |> hd() == "unpack ok"
    assert state(ctx).head == "refs/heads/beta"
  end

  test "the report goes on side-band 1 when asked, and only with report-status", ctx do
    # Without report-status there is no report at all.
    conn = push(ctx, [{@zero, ctx.a, "refs/heads/main"}], pack!(ctx, [ctx.a]), "side-band-64k")
    assert conn.status == 200
    assert conn.resp_body == ""

    conn =
      push(
        ctx,
        [{ctx.a, ctx.a, "refs/heads/main"}],
        pack!(ctx, [ctx.a, "^" <> ctx.a]),
        "report-status side-band-64k"
      )

    {:ok, [<<1, inner::binary>>, :flush]} = PktLine.decode(conn.resp_body)
    assert PktLine.decode(inner) == {:ok, ["unpack ok\n", "ok refs/heads/main\n", :flush]}
  end

  test "an oversized command section or pack is refused", ctx do
    opts = Keyword.put(ctx.opts, :max_command_bytes, 1000)
    ctx = %{ctx | opts: opts}
    line = PktLine.encode("#{@zero} #{ctx.a} refs/heads/#{String.duplicate("x", 1000)}\n")
    conn = post(ctx, IO.iodata_to_binary([line, PktLine.flush()]))
    assert conn.status == 413

    # Over the pack cap once stored, and over it while still arriving.
    for {max_pack_bytes, size} <- [{2000, 2500}, {100_000, 300_000}] do
      ctx = %{ctx | opts: Keyword.put(opts, :max_pack_bytes, max_pack_bytes)}
      pack = :crypto.strong_rand_bytes(size)

      assert report(push(ctx, [{@zero, ctx.a, "refs/heads/main"}], pack)) ==
               ["unpack pack too large", "ng refs/heads/main unpacker error"]
    end

    assert Repository.read_state(ctx.store, @repo) == {:ok, State.new(), :absent}
  end
end
