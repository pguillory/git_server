defmodule GitServer.WorkerTest do
  use ExUnit.Case, async: true
  alias GitServer.Worker

  test "the result, or an exit" do
    assert Worker.run(fn -> :done end, 1000) == {:ok, :done}
    assert Worker.run(fn -> exit(:boom) end, 1000) == :exited
  end
end
