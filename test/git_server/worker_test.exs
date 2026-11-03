defmodule GitServer.WorkerTest do
  use ExUnit.Case, async: true
  import GitServer.Worker

  test "the result, or an exit" do
    assert run(fn -> :done end, 1000) == {:ok, :done}
    assert run(fn -> exit(:boom) end, 1000) == :exited
  end
end
