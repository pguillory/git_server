defmodule GitServer.ShallowTest do
  # Shallow fetches, with real git as the oracle: each command runs against the server
  # and against a file:// copy of the same history, and the two clones must agree on
  # `.git/shallow` and on every commit they hold. Requests git never sends go through
  # Plug.Test.
  use ExUnit.Case, async: true
  import GitServer.TestGit
  import Plug.Conn, only: [put_req_header: 3]
  alias GitServer.PktLine
  alias GitServer.Shallow
  alias GitServer.TestServer

  @moduletag :tmp_dir

  # Test times are seconds after this. Git reads a small `@<n>` as something else.
  @base 1_700_000_000

  defp date(time) do
    [
      {"GIT_AUTHOR_DATE", "@#{@base + time} +0000"},
      {"GIT_COMMITTER_DATE", "@#{@base + time} +0000"},
    ]
  end

  # Commits a change to `file` in `dir` at test time `time`, returning its id.
  defp commit!(dir, file, time) do
    File.write!(Path.join(dir, file), "#{file} #{time}\n")
    {_, 0} = git(["add", "-A"], cd: dir)
    date = date(time)
    {_, 0} = git(["commit", "-q", "-m", "#{file} #{time}"], cd: dir, env: date)
    rev_parse!(dir, "HEAD")
  end

  defp rev_parse!(dir, rev) do
    {output, 0} = git(["rev-parse", rev], cd: dir)
    String.trim(output)
  end

  # A history with a merge, times 1000 to 9000, pushed to a new server:
  #
  #     c1 - c2 - c3 ------- m - c4 - c5   main, tagged v1 at c3 (annotated)
  #            \\           /
  #             s1 ------ s2
  defp setup_history!(tmp_dir) do
    source = Path.join(tmp_dir, "source")
    {_, 0} = git(["init", "-q", "-b", "main", source])
    commit!(source, "a", 1000)
    commit!(source, "a", 2000)
    {_, 0} = git(["branch", "side"], cd: source)
    commit!(source, "a", 3000)
    {_, 0} = git(["tag", "-a", "-m", "v1", "v1"], cd: source)
    {_, 0} = git(["checkout", "-q", "side"], cd: source)
    commit!(source, "b", 4000)
    commit!(source, "b", 5000)
    {_, 0} = git(["checkout", "-q", "main"], cd: source)
    {_, 0} = git(["merge", "-q", "--no-ff", "-m", "merge", "side"], cd: source, env: date(6000))
    commit!(source, "a", 7000)
    commit!(source, "a", 8000)

    server = TestServer.start!()
    push!(server, source)
    %{source: source, server: server}
  end

  defp push!(server, source) do
    {_, 0} = git(["push", "-q", TestServer.url(server, "repo"), "--all"], cd: source)
    {_, 0} = git(["push", "-q", TestServer.url(server, "repo"), "--tags"], cd: source)
  end

  # Runs `fun.(url, dir)` once against the server and once against the source over
  # file://, each in its own directory, and returns both directories.
  defp both(%{source: source, server: server}, tmp_dir, name, fun) do
    ours = Path.join(tmp_dir, name <> "-ours")
    theirs = Path.join(tmp_dir, name <> "-git")
    fun.(TestServer.url(server, "repo"), ours)
    fun.("file://" <> source, theirs)
    {ours, theirs}
  end

  defp assert_same({ours, theirs}) do
    assert shallow(ours) == shallow(theirs)
    assert commits(ours) == commits(theirs)
    assert {_, 0} = git(["fsck", "--full", "--strict"], cd: ours)
  end

  defp shallow(dir) do
    case File.read(Path.join(dir, ".git/shallow")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.sort()
      {:error, :enoent} -> []
    end
  end

  defp commits(dir) do
    {output, 0} = git(["rev-list", "--all"], cd: dir)
    output |> String.split("\n", trim: true) |> Enum.sort()
  end

  defp clone!(url, dir, args) do
    {output, 0} = git(["clone", "-q" | args] ++ [url, dir])
    output
  end

  test "clone --depth 1, and 3 across a merge", %{tmp_dir: tmp_dir} do
    history = setup_history!(tmp_dir)

    for depth <- [1, 3, 5] do
      dirs = both(history, tmp_dir, "depth#{depth}", &clone!(&1, &2, ["--depth", "#{depth}"]))
      assert_same(dirs)
      assert length(shallow(elem(dirs, 0))) >= 1
    end
  end

  test "fetch --deepen, --deepen relative to a merge, and --unshallow", %{tmp_dir: tmp_dir} do
    history = setup_history!(tmp_dir)

    dirs =
      both(history, tmp_dir, "deepen", fn url, dir ->
        clone!(url, dir, ["--depth", "1"])
        {_, 0} = git(["fetch", "-q", "--deepen", "2"], cd: dir)
      end)

    assert_same(dirs)

    for dir <- Tuple.to_list(dirs), do: {_, 0} = git(["fetch", "-q", "--deepen", "2"], cd: dir)
    assert_same(dirs)

    for dir <- Tuple.to_list(dirs), do: {_, 0} = git(["fetch", "-q", "--unshallow"], cd: dir)
    assert_same(dirs)
    assert shallow(elem(dirs, 0)) == []
    assert length(commits(elem(dirs, 0))) == 8
  end

  test "fetch --depth in a shallow clone moves the boundary", %{tmp_dir: tmp_dir} do
    history = setup_history!(tmp_dir)

    dirs =
      both(history, tmp_dir, "redepth", fn url, dir ->
        clone!(url, dir, ["--depth", "2"])
        {_, 0} = git(["fetch", "-q", "--depth", "4"], cd: dir)
      end)

    assert_same(dirs)
  end

  test "pull in a shallow clone after new pushes keeps the boundary", %{tmp_dir: tmp_dir} do
    history = setup_history!(tmp_dir)
    dirs = both(history, tmp_dir, "pull", &clone!(&1, &2, ["--depth", "1"]))

    commit!(history.source, "a", 9000)
    commit!(history.source, "c", 9100)
    push!(history.server, history.source)

    for dir <- Tuple.to_list(dirs), do: {_, 0} = git(["pull", "-q"], cd: dir)
    assert_same(dirs)
    assert File.read!(Path.join(elem(dirs, 0), "c")) == "c 9100\n"
  end

  test "clone --shallow-since", %{tmp_dir: tmp_dir} do
    history = setup_history!(tmp_dir)

    for since <- [4500, 2500, 7000] do
      args = ["--shallow-since", "@#{@base + since}"]
      dirs = both(history, tmp_dir, "since#{since}", &clone!(&1, &2, args))
      assert_same(dirs)
      assert shallow(elem(dirs, 0)) != []
    end
  end

  test "clone --depth 1 --branch <tag>", %{tmp_dir: tmp_dir} do
    history = setup_history!(tmp_dir)
    args = ["--depth", "1", "--branch", "v1"]
    dirs = both(history, tmp_dir, "tag", &clone!(&1, &2, args))
    assert_same(dirs)
    assert rev_parse!(elem(dirs, 0), "HEAD") == rev_parse!(history.source, "v1^{commit}")
  end

  test "a shallow clone of an empty repository", %{tmp_dir: tmp_dir} do
    server = TestServer.start!()
    dir = Path.join(tmp_dir, "empty")
    output = clone!(TestServer.url(server, "repo"), dir, ["--depth", "1"])
    assert output =~ "You appear to have cloned an empty repository."
    assert shallow(dir) == []
  end

  describe "requests git never sends" do
    setup %{tmp_dir: tmp_dir} do
      history = setup_history!(tmp_dir)
      tip = rev_parse!(history.source, "main")
      tree = rev_parse!(history.source, "main^{tree}")
      Map.merge(history, %{tip: tip, tree: tree})
    end

    defp fetch(server, arguments) do
      body = [
        PktLine.encode("command=fetch\n"),
        PktLine.encode("object-format=sha1\n"),
        PktLine.delim(),
        Enum.map(arguments, &PktLine.encode(&1 <> "\n")),
        PktLine.flush(),
      ]

      conn =
        Plug.Test.conn(:post, "/repo/git-upload-pack", IO.iodata_to_binary(body))
        |> put_req_header("git-protocol", "version=2")
        |> GitServer.Plug.call(
          GitServer.Plug.init(store: server.store, authorize: fn _ -> :ok end)
        )

      assert conn.status == 200
      {:ok, packets} = PktLine.decode(conn.resp_body)
      packets
    end

    test "an unknown shallow is ignored, a non-commit refused", %{server: server} = context do
      unknown = String.duplicate("1", 40)

      assert ["shallow-info\n", "shallow " <> boundary, :delim, "packfile\n" | _] =
               fetch(server, ["want #{context.tip}", "shallow #{unknown}", "deepen 1", "done"])

      assert boundary == context.tip <> "\n"

      # A shallow line alone, with nothing to deepen, still gets its (empty) section.
      assert ["shallow-info\n", :delim, "packfile\n" | _] =
               fetch(server, ["want #{context.tip}", "shallow #{context.tip}", "done"])

      assert [packet] =
               fetch(server, ["want #{context.tip}", "shallow #{context.tree}", "deepen 1"])

      assert packet == "ERR invalid shallow object #{context.tree}\n"
    end

    test "deepen with deepen-since, and bad values", %{server: server, tip: tip} do
      for {arguments, message} <- [
            {["deepen 1", "deepen-since 1000"],
             "deepen and deepen-since cannot be used together"},
            {["deepen 0"], "invalid deepen \"0\""},
            {["deepen -1"], "invalid deepen \"-1\""},
            {["deepen #{Shallow.max_depth() + 1}"], "invalid deepen"},
            {["deepen-since soon"], "invalid deepen-since \"soon\""},
            {["shallow abc"], "malformed shallow"},
          ] do
        assert [packet] = fetch(server, ["want #{tip}" | arguments] ++ ["done"])
        assert String.starts_with?(packet, "ERR " <> message), inspect({arguments, packet})
      end
    end

    test "without done, shallow-info follows the acknowledgments", context do
      %{server: server, tip: tip} = context
      have = rev_parse!(context.source, "main~1")

      assert [
               "acknowledgments\n",
               "ACK " <> ack,
               "ready\n",
               :delim,
               "shallow-info\n",
               "shallow " <> boundary,
               :delim,
               "packfile\n" | _
             ] = fetch(server, ["want #{tip}", "have #{have}", "deepen 1"])

      assert ack == have <> "\n"
      assert boundary == tip <> "\n"
    end

    test "--unshallow's depth is cheap and has no boundary", %{server: server, tip: tip} do
      assert ["shallow-info\n", :delim, "packfile\n" | _] =
               fetch(server, ["want #{tip}", "deepen #{Shallow.max_depth()}", "done"])
    end

    test "a shallow commit no ref reaches isn't deepened", %{server: server} = context do
      # Two commits only a deleted branch reached.
      url = TestServer.url(server, "repo")
      {_, 0} = git(["checkout", "-q", "-b", "lost"], cd: context.source)
      first = commit!(context.source, "lost", 9500)
      side = commit!(context.source, "lost", 9600)
      {_, 0} = git(["push", "-q", url, "lost"], cd: context.source)
      {_, 0} = git(["push", "-q", url, ":lost"], cd: context.source)

      packets =
        fetch(server, [
          "want #{context.tip}",
          "shallow #{side}",
          "deepen 1",
          "deepen-relative",
          "done",
        ])

      assert ["shallow-info\n", :delim, "packfile\n" | _] = packets
      refute Enum.any?(packets, &(&1 == "unshallow #{side}\n"))
      refute Enum.any?(packets, &(&1 == "shallow #{first}\n"))
    end
  end

  test "committer time" do
    commit = "tree x\nauthor A <a> 5 +0000\ncommitter C <c> 1700000000 -0700\n\nmsg >9\n"
    assert Shallow.committer_time(commit) == 1_700_000_000
    assert Shallow.committer_time("tree x\ncommitter C <c> +5 +0000\n\n") == 0
    assert Shallow.committer_time("tree x\ncommitter C <c>\n\n") == 0
    assert Shallow.committer_time("tree x\n\ncommitter C <c> 5 +0000\n") == 0
    many = "tree x\ncommitter C <c#{String.duplicate(">", 1_000_000)} 7 +0000\n\n"
    assert Shallow.committer_time(many) == 7
    long = String.duplicate("9", 20)
    assert Shallow.committer_time("tree x\ncommitter C <c> #{long} +0000\n") == 0
  end
end
