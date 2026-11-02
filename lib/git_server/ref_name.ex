defmodule GitServer.RefName do
  @moduledoc """
  Ref names a push may create, by git's `check-ref-format` rules, under `refs/`.

  A name is `/`-separated components, none empty, none starting with `.` or ending
  with `.lock`. It has no `..`, no `@{`, no control characters, space, `~`, `^`,
  `:`, `?`, `*`, `[` or backslash, and doesn't end with `.`. It must start with
  `refs/` and have at least one component after it, as git's receive-pack requires,
  and be at most 1024 bytes, so every advertisement and report line that holds it
  fits in one pkt-line.
  """

  @max_bytes 1024

  @doc "Whether `name` is a ref name a push may update."
  def valid?(name) when is_binary(name) do
    with true <- byte_size(name) <= @max_bytes,
         "refs/" <> rest when rest != "" <- name,
         false <- String.contains?(name, ["..", "@{"]),
         false <- String.ends_with?(name, "."),
         false <- name =~ ~r/[\x00-\x20\x7f~^:?*\[\\]/ do
      name |> String.split("/") |> Enum.all?(&valid_component?/1)
    else
      _ -> false
    end
  end

  defp valid_component?(component) do
    component != "" and not String.starts_with?(component, ".") and
      not String.ends_with?(component, ".lock")
  end
end
