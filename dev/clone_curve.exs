# Measures how clones and pushes slow down as pushes pile up, for a repository shaped
# like a rule set: a few small text files and one small commit per push. Every pack
# stays listed, so this is the cost of having no compaction.
#
#     bin/test-s3-local start
#     (set -a; source tmp/test-s3.env; set +a; mix run dev/clone_curve.exs)
#
# Any file of GIT_SERVER_TEST_S3_* lines works in place of tmp/test-s3.env. It works
# under a fresh test-curve-<random>/ prefix and deletes it at the end.
#
# Options:
#   --points 1,10,100    the push counts to measure at
#   --clones 5           clones from a fresh directory at each point
#   --real-until 100     every push up to here goes through git
#   --timed-pushes 3     pushes through git just before each later point, and timed
#   --pack-cache MODE    serve with a pack cache: "cold" empties it before each clone,
#                        "warm" fills it with an untimed clone first (default no cache)
#
# Clones and timed pushes always use the real git client, against the server on
# loopback. Between them, to save hours, the other pushes are a shortcut that writes
# what a push writes: the pack `git pack-objects` makes with send-pack's own arguments,
# its idx from the server's own indexer, and the state with that pack appended. Each
# real push checks this by making that pack first and comparing it to the one the
# server listed, and the "same packs" count in the output reports the result.
#
# Columns: pushes; clones that succeeded; clone wall time mean, min and max in ms; the
# S3 GETs and KB read per clone; the ms per clone spent inside S3 GETs, the rest being
# git and the server's own work; pack KB received by git; mean ms and S3 GETs of the
# timed pushes.
#
# Set ulimit -n to check the server's open files: a request holds only a few packs open
# at once (ObjectDB's :max_open_files), whatever the pack count.
defmodule CloneCurve do
  defmodule CountingStore do
    @moduledoc "Delegates to another store, counting GETs, their bytes and their time."
    @behaviour GitServer.Store
    alias GitServer.Store

    def wrap(store) do
      {__MODULE__, %{inner: store, counts: :counters.new(3, [])}}
    end

    def read({__MODULE__, %{counts: counts}}) do
      %{
        gets: :counters.get(counts, 1),
        bytes: :counters.get(counts, 2),
        us: :counters.get(counts, 3),
      }
    end

    defp counted(config, fun, size) do
      started = System.monotonic_time(:microsecond)
      result = fun.()
      :counters.add(config.counts, 1, 1)
      :counters.add(config.counts, 3, System.monotonic_time(:microsecond) - started)
      :counters.add(config.counts, 2, size.(result))
      result
    end

    @impl true
    def get(config, key) do
      counted(config, fn -> Store.get(config.inner, key) end, fn
        {:ok, body, _etag} -> byte_size(body)
        _error -> 0
      end)
    end

    @impl true
    def get_file(config, key, path) do
      counted(config, fn -> Store.get_file(config.inner, key, path) end, fn
        {:ok, _etag} -> File.stat!(path).size
        _error -> 0
      end)
    end

    @impl true
    def put(config, key, body, condition), do: Store.put(config.inner, key, body, condition)

    @impl true
    def put_file(config, key, path, condition),
      do: Store.put_file(config.inner, key, path, condition)

    @impl true
    def delete(config, key), do: Store.delete(config.inner, key)

    @impl true
    def list(config, prefix), do: Store.list(config.inner, prefix)

    @impl true
    def describe(config), do: "counting " <> Store.describe(config.inner)
  end

  alias GitServer.{Repository, Store}
  alias GitServer.Pack.Indexer

  @repo "rules"
  @ref "refs/heads/main"
  @files 20
  @lines 40

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          points: :string,
          clones: :integer,
          real_until: :integer,
          timed_pushes: :integer,
          pack_cache: :string,
        ]
      )

    points =
      (opts[:points] || "1,10,100,500,1000,2000,3000")
      |> String.split(",")
      |> Enum.map(&String.to_integer/1)

    unless opts[:pack_cache] in [nil, "cold", "warm"],
      do: raise(ArgumentError, "--pack-cache is cold or warm")

    work = Path.join(System.tmp_dir!(), "git_server-curve-#{random()}")
    File.mkdir_p!(work)

    run = %{
      work: work,
      local: Path.join(work, "local"),
      clones: opts[:clones] || 5,
      real_until: opts[:real_until] || 100,
      timed_pushes: opts[:timed_pushes] || 3,
      git_env: git_env(work),
      pack_cache: opts[:pack_cache],
      cache_dir: Path.join(work, "pack-cache"),
    }

    inner = inner_store()
    store = CountingStore.wrap(inner)
    run = Map.merge(run, %{store: store, url: serve(store, run.pack_cache && run.cache_dir)})

    try do
      git!(run, ["init", "-q", "-b", "main", run.local], work)
      git!(run, ["remote", "add", "origin", run.url], run.local)
      header()
      {_pushes, same, compared} = Enum.reduce(points, {0, 0, 0}, &point(run, &1, &2))
      IO.puts("same packs: #{same} of #{compared} real pushes matched the shortcut's pack")
    after
      File.rm_rf!(work)
      {:ok, objects} = Store.list(inner, "")
      Enum.each(objects, &(:ok = Store.delete(inner, &1.key)))
    end
  end

  defp inner_store do
    setting = fn name -> System.get_env("GIT_SERVER_TEST_S3_" <> name) end

    {:ok, store} =
      GitServer.Store.S3.new(
        endpoint: setting.("ENDPOINT"),
        bucket: setting.("BUCKET"),
        region: setting.("REGION"),
        access_key_id: setting.("ACCESS_KEY_ID"),
        secret_access_key: setting.("SECRET_ACCESS_KEY"),
        prefix: "test-curve-#{random()}/"
      )

    store
  end

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp serve(store, cache_dir) do
    authorize = fn
      %{credentials: {"curve", "curve"}} -> :ok
      _request -> :unauthorized
    end

    {:ok, pid} =
      Bandit.start_link(
        plug: {GitServer.Plug, store: store, authorize: authorize, pack_cache_dir: cache_dir},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://curve:curve@127.0.0.1:#{port}/#{@repo}"
  end

  # The same isolation as the tests: no developer config, credential helper or prompt.
  defp git_env(work) do
    config = Path.join(work, "gitconfig")
    File.write!(config, "[user]\n\tname = Curve\n\temail = curve@example.com\n")

    inherited =
      for {name, _value} <- System.get_env(), String.starts_with?(name, "GIT_"), do: {name, nil}

    inherited ++
      [
        {"HOME", work},
        {"XDG_CONFIG_HOME", work},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", config},
        {"GIT_TERMINAL_PROMPT", "0"},
      ]
  end

  defp git(run, args, dir) do
    System.cmd("git", ["-c", "credential.helper=" | args],
      cd: dir,
      env: run.git_env,
      stderr_to_stdout: true
    )
  end

  defp git!(run, args, dir) do
    {output, 0} = git(run, args, dir)
    output
  end

  # Brings the repository to `target` pushes, then measures clones there.
  defp point(run, target, {pushes, same, compared}) do
    timed_from = max(run.real_until, target - run.timed_pushes) + 1
    timed = max(1, target - timed_from + 1)

    {same, compared, timings} =
      Enum.reduce((pushes + 1)..target//1, {same, compared, []}, &push(run, &1, timed_from, &2))

    report(run, target, Enum.take(timings, timed), measure_clones(run, target))
    {target, same, compared}
  end

  # One push, through git (timed, and checked against the shortcut's pack) or the shortcut.
  defp push(run, count, timed_from, {same, compared, timings}) do
    commit!(run, count)
    pack = local_pack!(run, count)

    if count <= run.real_until or count >= timed_from do
      before = CountingStore.read(run.store)
      started = System.monotonic_time(:millisecond)
      git!(run, ["push", "-q", "origin", "main"], run.local)
      elapsed = System.monotonic_time(:millisecond) - started
      gets = CountingStore.read(run.store).gets - before.gets
      {:ok, state, _etag} = Repository.read_state(inner(run), @repo)
      File.rm!(pack.path)
      same = if List.last(state.packs) == pack.name, do: same + 1, else: same
      {same, compared + 1, [{elapsed, gets} | timings]}
    else
      write_as_push!(run, pack)
      {same, compared, timings}
    end
  end

  defp inner({_mod, config}), do: config.inner
  defp inner(%{store: store}), do: inner(store)

  defp commit!(run, count) do
    if count == 1 do
      File.mkdir_p!(Path.join(run.local, "rules"))

      for file <- 1..@files do
        File.write!(rule_path(run, file), Enum.map_join(1..@lines, &line(file, &1, "as written")))
      end

      git!(run, ["add", "-A"], run.local)
      git!(run, ["commit", "-q", "-m", "first"], run.local)
    else
      file = rem(count, @files) + 1
      line_no = rem(count, @lines) + 1
      lines = rule_path(run, file) |> File.read!() |> String.split("\n", trim: true)

      changed =
        List.replace_at(
          lines,
          line_no - 1,
          String.trim(line(file, line_no, "changed in #{count}"))
        )

      File.write!(rule_path(run, file), Enum.join(changed, "\n") <> "\n")
      git!(run, ["commit", "-q", "-a", "-m", "change #{count}"], run.local)
    end
  end

  defp rule_path(run, file), do: Path.join(run.local, "rules/rule-#{file}.txt")

  defp line(file, line_no, note),
    do: "rule #{file} clause #{line_no}: allow this action, #{note}\n"

  # The pack `git push` would send for the newest commit, with send-pack's arguments
  # (thin packs off, since the server advertises no-thin).
  defp local_pack!(run, count) do
    path = Path.join(run.work, "push-#{count}.pack")
    revs = if count == 1, do: "HEAD", else: "HEAD\\n^HEAD~1"

    {_, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          "printf '#{revs}\\n' | git pack-objects --all-progress-implied --revs --stdout --delta-base-offset -q > #{path}",
        ],
        cd: run.local,
        env: run.git_env
      )

    size = File.stat!(path).size
    fd = File.open!(path, [:read, :binary, :raw])
    {:ok, trailer} = :file.pread(fd, size - 20, 20)
    File.close(fd)
    %{path: path, name: Base.encode16(trailer, case: :lower)}
  end

  # What a push writes, in its order: pack, idx, then the state with the pack appended.
  defp write_as_push!(run, pack) do
    store = inner(run)
    {:ok, indexed} = Indexer.index(pack.path)
    {:ok, _} = Store.put_file(store, Repository.pack_key(@repo, pack.name), pack.path, :none)
    {:ok, _} = Store.put(store, Repository.idx_key(@repo, pack.name), indexed.idx, :none)
    File.rm!(pack.path)
    {:ok, state, etag} = Repository.read_state(store, @repo)
    head = run |> git!(["rev-parse", "HEAD"], run.local) |> String.trim()
    state = %{state | packs: state.packs ++ [pack.name], refs: %{@ref => head}}
    {:ok, _} = Repository.put_state(store, @repo, state, etag)
  end

  defp measure_clones(run, target) do
    head = run |> git!(["rev-parse", "HEAD"], run.local) |> String.trim()

    if run.pack_cache == "warm",
      do: git!(run, ["clone", "-q", run.url, Path.join(run.work, "warm-#{target}")], run.work)

    for n <- 1..run.clones do
      dir = Path.join(run.work, "clone-#{target}-#{n}")
      if run.pack_cache == "cold", do: File.rm_rf!(run.cache_dir)
      before = CountingStore.read(run.store)
      started = System.monotonic_time(:millisecond)
      {output, status} = git(run, ["clone", "-q", run.url, dir], run.work)
      elapsed = System.monotonic_time(:millisecond) - started
      counted = CountingStore.read(run.store)

      result = %{
        ms: elapsed,
        ok: status == 0,
        gets: counted.gets - before.gets,
        kb: (counted.bytes - before.bytes) / 1024,
        s3_ms: (counted.us - before.us) / 1000,
        error: status != 0 && output |> String.split("\n") |> List.first(),
      }

      result =
        if status == 0 do
          # Checked outside the timing, on the first clone at each point.
          if n == 1, do: git!(run, ["fsck", "--full"], dir)
          ^head = run |> git!(["rev-parse", "HEAD"], dir) |> String.trim()
          Map.put(result, :pack_kb, pack_kb(dir))
        else
          result
        end

      File.rm_rf!(dir)
      result
    end
  end

  defp pack_kb(dir) do
    dir
    |> Path.join(".git/objects/pack/*.pack")
    |> Path.wildcard()
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
    |> Kernel./(1024)
  end

  defp header do
    IO.puts(
      "| pushes | ok | clone ms | min | max | GETs | KB read | ms in GETs | pack KB | push ms | push GETs |"
    )

    IO.puts("|---|---|---|---|---|---|---|---|---|---|---|")
  end

  defp report(run, target, pushes, results) do
    ok = Enum.filter(results, & &1.ok)

    mean = fn list, key ->
      if list == [], do: 0, else: Enum.sum(Enum.map(list, key)) / length(list)
    end

    ms = Enum.map(results, & &1.ms)

    row = [
      target,
      "#{length(ok)}/#{run.clones}",
      round(mean.(results, & &1.ms)),
      Enum.min(ms),
      Enum.max(ms),
      round(mean.(results, & &1.gets)),
      round(mean.(results, & &1.kb)),
      round(mean.(results, & &1.s3_ms)),
      round(mean.(ok, & &1.pack_kb)),
      round(mean.(pushes, &elem(&1, 0))),
      round(mean.(pushes, &elem(&1, 1))),
    ]

    IO.puts("| " <> Enum.join(row, " | ") <> " |")

    results
    |> Enum.reject(& &1.ok)
    |> Enum.take(1)
    |> Enum.each(&IO.puts("clone failed at #{target} pushes: #{&1.error}"))
  end
end

Logger.configure(level: :warning)
CloneCurve.main(System.argv())
