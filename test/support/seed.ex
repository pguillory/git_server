defmodule GitServer.Seed do
  @moduledoc """
  Puts a repository in the store from a real git repository, without a push: packs
  and idx files written by `git pack-objects`, under the store layout, and a `state`
  listing them. A source is `%{home: home, repo: path}`, as `source!/1` and
  `GitServer.GitFixture.build!/1` return.
  """

  import GitServer.LocalGit
  alias GitServer.{Repository, State, Store}

  @doc "An empty source repository under `dir`."
  def source!(dir) do
    home = Path.join(dir, "source-home")
    repo = Path.join(home, "repo")
    File.mkdir_p!(repo)
    git!(home, repo, ["init", "-q"])
    %{home: home, repo: repo}
  end

  @doc "Writes `file` in the source and commits it, returning the commit's id in hex."
  def commit!(source, file, content) do
    File.write!(Path.join(source.repo, file), content)
    git!(source.home, source.repo, ["add", "-A"])
    git!(source.home, source.repo, ["commit", "-q", "-m", "change #{file}"])
    rev_parse!(source, "HEAD")
  end

  @doc "Resolves a revision in the source to its id in hex."
  def rev_parse!(source, rev) do
    String.trim(git!(source.home, source.repo, ["rev-parse", rev]))
  end

  @doc """
  Adds a pack of the objects `revs` selects (arguments of `git rev-list`), then makes
  the state's refs and HEAD match the source's. Returns the pack's name.
  """
  def push!(store, name, source, revs \\ ["--all"]) do
    pack = add_pack!(store, name, source, revs)

    update_state!(
      store,
      name,
      &%{&1 | packs: &1.packs ++ [pack], refs: refs(source), head: head(source)}
    )

    pack
  end

  @doc "Adds a pack of the objects `revs` selects, and lists it, without touching any ref."
  def push_pack_only!(store, name, source, revs) do
    pack = add_pack!(store, name, source, revs)
    update_state!(store, name, &%{&1 | packs: &1.packs ++ [pack]})
    pack
  end

  defp add_pack!(store, name, source, revs) do
    %{home: home, repo: repo} = source
    list = Path.join(home, "objects-#{System.unique_integer([:positive])}")
    File.write!(list, git!(home, repo, ["rev-list", "--objects" | revs]))
    base = Path.join(home, "seed-#{System.unique_integer([:positive])}")
    git!(home, repo, ["pack-objects", "-q", base], input: list)
    [pack_path] = Path.wildcard(base <> "-*.pack")
    idx_path = Path.rootname(pack_path) <> ".idx"
    pack = trailer_hex(pack_path)
    {:ok, _} = Store.put_file(store, Repository.idx_key(name, pack), idx_path, :none)
    {:ok, _} = Store.put_file(store, Repository.pack_key(name, pack), pack_path, :none)
    pack
  end

  defp trailer_hex(path) do
    bytes = File.read!(path)
    bytes |> binary_part(byte_size(bytes) - 20, 20) |> Base.encode16(case: :lower)
  end

  defp update_state!(store, name, fun) do
    {:ok, state, etag} = Repository.read_state(store, name)
    {:ok, _} = Repository.put_state(store, name, %State{} = fun.(state), etag)
  end

  defp refs(%{home: home, repo: repo}) do
    git!(home, repo, ["for-each-ref", "--format=%(refname) %(objectname)"])
    |> String.split("\n", trim: true)
    |> Map.new(fn line -> List.to_tuple(String.split(line, " ")) end)
  end

  defp head(%{home: home, repo: repo}) do
    String.trim(git!(home, repo, ["symbolic-ref", "HEAD"]))
  end
end
