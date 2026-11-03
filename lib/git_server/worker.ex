defmodule GitServer.Worker do
  @moduledoc false
  # Runs a function in a process of its own, for host callbacks and work that a
  # timeout or the end of a request must be able to stop.

  # Runs `fun` in a process of its own, unlinked so that nothing it does can take the
  # request down: `{:ok, result}`, `:exited` if it died first, or `:timeout`, when it
  # is killed. Before running `fun`, the worker starts a guard that kills it if the
  # request process dies, so it never outlives the request.
  def run(fun, timeout) do
    caller = self()
    callers = [caller | Process.get(:"$callers", [])]
    tag = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> guard(caller, worker) end)
        # As `Task` does, for hosts whose test tools follow the calling process.
        Process.put(:"$callers", callers)
        send(caller, {tag, fun.()})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :exited
    after
      timeout ->
        Process.exit(worker, :kill)

        # The worker's last message, if any, comes before its :DOWN.
        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        end

        receive do
          {^tag, _result} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  # Waits for `caller` or `worker` to die, and kills `worker` if `caller` died first.
  defp guard(caller, worker) do
    caller_monitor = Process.monitor(caller)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^caller_monitor, :process, _pid, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_monitor, :process, _pid, _reason} -> :ok
    end
  end
end
