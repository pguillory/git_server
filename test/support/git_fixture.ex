defmodule GitServer.GitFixture do
  @moduledoc """
  A repository built with the real git client, with history that forces deltas and
  every kind of object and tree entry, and the packs git writes for it.

  History: several commits editing a 200 KB text file, an empty blob, a binary file, an
  executable, a symlink, a nested tree, a gitlink entry and an annotated tag. Packs:

    * `:repacked` - `git repack -adf --window=50` (OFS_DELTA)
    * `:ofs` - `git pack-objects --no-reuse-delta --delta-base-offset` (OFS_DELTA)
    * `:ref` - `git pack-objects --no-reuse-delta` (REF_DELTA)

  Each pack is `{pack_path, idx_path}`, the idx written by git.
  """

  import GitServer.LocalGit

  def build!(home) do
    repo = Path.join(home, "repo")
    File.mkdir_p!(repo)
    git!(home, repo, ["init", "-q"])

    lines = for i <- 1..4000, do: "line #{i} of a synthetic text file used to force deltas\n"
    File.mkdir_p!(Path.join(repo, "a/b/c"))
    File.write!(Path.join(repo, "a/b/c/nested.txt"), "nested\n")
    File.write!(Path.join(repo, "empty"), "")
    File.write!(Path.join(repo, "binary.bin"), :crypto.strong_rand_bytes(50_000))
    File.write!(Path.join(repo, "run.sh"), "#!/bin/sh\necho hi\n")
    File.chmod!(Path.join(repo, "run.sh"), 0o755)
    File.ln_s!("a/b/c/nested.txt", Path.join(repo, "link"))

    for round <- 1..6 do
      edited =
        Enum.map(Enum.with_index(lines), fn {line, i} ->
          if rem(i, 97) == round, do: "edited in round #{round}: #{line}", else: line
        end)

      File.write!(Path.join(repo, "big.txt"), edited)
      File.write!(Path.join(repo, "a/round.txt"), "round #{round}\n")
      git!(home, repo, ["add", "-A"])
      git!(home, repo, ["commit", "-q", "-m", "round #{round}"])
    end

    head = String.trim(git!(home, repo, ["rev-parse", "HEAD"]))
    git!(home, repo, ["update-index", "--add", "--cacheinfo", "160000,#{head},sub"])
    git!(home, repo, ["commit", "-q", "-m", "add a gitlink"])
    git!(home, repo, ["tag", "-a", "v1", "-m", "version one"])
    git!(home, repo, ["repack", "-q", "-adf", "--window=50"])

    [repacked] = Path.wildcard(Path.join(repo, ".git/objects/pack/*.pack"))

    objects = Path.join(home, "objects.txt")
    File.write!(objects, git!(home, repo, ["rev-list", "--objects", "--all"]))

    %{
      home: home,
      repo: repo,
      packs: %{
        repacked: {repacked, Path.rootname(repacked) <> ".idx"},
        ofs: pack_objects(home, repo, objects, "ofs", ["--delta-base-offset"]),
        ref: pack_objects(home, repo, objects, "ref", []),
      },
    }
  end

  defp pack_objects(home, repo, objects, name, flags) do
    base = Path.join(home, name)
    args = ["pack-objects", "-q", "--no-reuse-delta", "--window=50"] ++ flags ++ [base]
    checksum = String.trim(git!(home, repo, args, input: objects))
    {"#{base}-#{checksum}.pack", "#{base}-#{checksum}.idx"}
  end

  @doc "Every object in the repository: `{id_hex, type, content}`, from `git cat-file`."
  def objects(%{home: home, repo: repo}) do
    git!(home, repo, ["cat-file", "--batch-all-objects", "--batch"]) |> parse_batch([])
  end

  defp parse_batch("", acc) do
    Enum.reverse(acc)
  end

  defp parse_batch(out, acc) do
    [header, rest] = :binary.split(out, "\n")
    [hex, type, size] = String.split(header, " ")
    size = String.to_integer(size)
    <<content::binary-size(size), "\n", rest::binary>> = rest
    parse_batch(rest, [{hex, String.to_existing_atom(type), content} | acc])
  end
end
