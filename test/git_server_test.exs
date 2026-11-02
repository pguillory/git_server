defmodule GitServerTest do
  use ExUnit.Case, async: true

  test "version" do
    assert GitServer.version() =~ ~r/^\d+\.\d+\.\d+/
  end
end
