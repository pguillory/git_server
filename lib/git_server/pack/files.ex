defmodule GitServer.Pack.Files do
  @moduledoc """
  A bounded set of open pack files, so a reader of many packs holds only a few open
  at once whatever the pack count.

  Files are opened on first use, and opening one when `max_open` are open first
  closes the least recently used, so no more than `max_open` are ever open. A file
  handed out stays valid until the next call to `fd/3`, which may close it. The set
  lives in two private ETS tables owned by the calling process, which also owns the
  raw file handles, so all of it goes away with that process or with `close/1`.
  """

  defstruct [:table, :order, :max_open]

  @type t :: %__MODULE__{}

  @doc "Creates an empty set holding at most `max_open` (at least 1) files open."
  def new(max_open) when is_integer(max_open) and max_open >= 1 do
    table = :ets.new(__MODULE__, [:set, :private])
    order = :ets.new(__MODULE__, [:ordered_set, :private])
    :ets.insert(table, {:seq, 0})
    %__MODULE__{table: table, order: order, max_open: max_open}
  end

  @doc """
  The open file for `key`, opening `path` if it isn't open: `{:ok, fd}` or
  `{:error, posix}`. Every other file handed out before may now be closed.
  """
  def fd(%__MODULE__{table: table, order: order} = files, key, path) do
    seq = :ets.update_counter(table, :seq, 1)

    case :ets.lookup(table, {:file, key}) do
      [{_, fd, old}] ->
        :ets.delete(order, old)
        :ets.insert(order, {seq, key})
        :ets.insert(table, {{:file, key}, fd, seq})
        {:ok, fd}

      [] ->
        # Close first, so this process never holds more than max_open.
        if :ets.info(order, :size) >= files.max_open, do: close_oldest(files)

        with {:ok, fd} <- :file.open(path, [:read, :raw, :binary]) do
          :ets.insert(order, {seq, key})
          :ets.insert(table, {{:file, key}, fd, seq})
          {:ok, fd}
        end
    end
  end

  @doc "The number of files open now."
  def open_count(%__MODULE__{order: order}), do: :ets.info(order, :size)

  defp close_oldest(%__MODULE__{table: table, order: order}) do
    seq = :ets.first(order)
    [{^seq, key}] = :ets.lookup(order, seq)
    [{_, fd, ^seq}] = :ets.lookup(table, {:file, key})
    :ets.delete(order, seq)
    :ets.delete(table, {:file, key})
    File.close(fd)
  end

  @doc "Closes every open file and deletes the tables."
  def close(%__MODULE__{table: table, order: order}) do
    :ets.foldl(
      fn
        {{:file, _key}, fd, _seq}, :ok ->
          File.close(fd)
          :ok

        _other, :ok ->
          :ok
      end,
      :ok,
      table
    )

    :ets.delete(table)
    :ets.delete(order)
    :ok
  end
end
