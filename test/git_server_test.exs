defmodule GitServerTest do
  use ExUnit.Case, async: true
  import GitServer

  test "version" do
    assert version() =~ ~r/^\d+\.\d+\.\d+/
  end
end
