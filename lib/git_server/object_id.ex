defmodule GitServer.ObjectId do
  @moduledoc """
  Git object ids: SHA-1, 20 raw bytes, written as 40 lowercase hex digits.

  The hash and its length live only here, so supporting SHA-256 later is a change to
  this module and its callers' assumptions about `size/0`.
  """

  @size 20

  @typedoc "A raw object id (20 bytes)."
  @type t :: <<_::160>>

  @doc "The length of a raw id in bytes."
  def size do
    @size
  end

  @doc "The all-zero id git uses for \"no object\"."
  def zero do
    <<0::size(@size * 8)>>
  end

  @doc "Hashes iodata in one call."
  def hash(iodata) do
    :crypto.hash(:sha, iodata)
  end

  @doc "Starts an incremental hash."
  def hash_init do
    :crypto.hash_init(:sha)
  end

  @doc "Adds iodata to an incremental hash."
  def hash_update(state, iodata) do
    :crypto.hash_update(state, iodata)
  end

  @doc "Finishes an incremental hash."
  def hash_final(state) do
    :crypto.hash_final(state)
  end

  @doc "Encodes a raw id as lowercase hex."
  def to_hex(<<_::binary-size(@size)>> = id) do
    Base.encode16(id, case: :lower)
  end

  @doc "Decodes 40 hex digits (either case) into a raw id."
  def from_hex(hex) when is_binary(hex) and byte_size(hex) == @size * 2 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  def from_hex(_) do
    :error
  end
end
