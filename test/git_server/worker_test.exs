defmodule GitServer.WorkerTest do
  use ExUnit.Case, async: true
  alias GitServer.Worker

  test "the result, an exit, or a timeout that kills the worker" do
    assert Worker.run(fn -> :done end, 1000) == {:ok, :done}
    assert Worker.run(fn -> exit(:boom) end, 1000) == :exited

    test = self()

    assert Worker.run(fn -> send(test, {:worker, self()}) && Process.sleep(:infinity) end, 50) ==
             :timeout

    assert_received {:worker, worker}
    refute Process.alive?(worker)
  end

  test "the worker is killed when its caller dies" do
    test = self()

    caller =
      spawn(fn ->
        Worker.run(fn -> send(test, {:worker, self()}) && Process.sleep(:infinity) end, :infinity)
      end)

    assert_receive {:worker, worker}
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
  end
end
