defmodule Zed.Converge.HealthTest do
  use ExUnit.Case, async: false

  alias Zed.Converge.Health

  # Scripted stub Checker. Per-host queue of responses; each
  # check/4 call pops the head. A response of `{:hang, ref, test_pid}`
  # tells the worker to send `{:hanging, host, ref, self()}` to the
  # test and block until the test replies `{:release, ref, response}`.
  defmodule StubChecker do
    @behaviour Zed.Converge.Health.Checker

    @impl true
    def check(host, _type, _opts, _timeout) do
      response =
        Agent.get_and_update(__MODULE__.Script, fn script ->
          case Map.get(script, host, []) do
            [head | tail] -> {head, Map.put(script, host, tail)}
            [] -> {:default_pass, script}
          end
        end)

      case response do
        :default_pass ->
          :ok

        :ok ->
          :ok

        {:error, _reason} = err ->
          err

        {:hang, ref, test_pid} ->
          send(test_pid, {:hanging, host, ref, self()})

          receive do
            {:release, ^ref, reply} -> reply
          after
            30_000 -> {:error, :test_stub_timeout}
          end
      end
    end

    def start_script(script) when is_map(script) do
      # Unlinked so the agent survives the test process exiting; the on_exit
      # callback stops it explicitly.
      {:ok, _pid} = Agent.start(fn -> script end, name: __MODULE__.Script)
      :ok
    end

    def stop_script do
      case Process.whereis(__MODULE__.Script) do
        nil -> :ok
        pid -> try do
                 Agent.stop(pid)
               catch
                 :exit, _ -> :ok
               end
      end
    end
  end

  setup do
    on_exit(fn -> StubChecker.stop_script() end)
    :ok
  end

  defp start_health_async(targets, opts) do
    test_pid = self()

    runner =
      spawn_link(fn ->
        result =
          Health.run(
            targets,
            Keyword.put(opts, :on_start, fn pid -> send(test_pid, {:health_pid, pid}) end)
          )

        send(test_pid, {:result, result})
      end)

    health_pid =
      receive do
        {:health_pid, pid} -> pid
      after
        2_000 ->
          flunk("Health orchestrator never reported its pid")
      end

    {runner, health_pid}
  end

  defp await_result do
    receive do
      {:result, result} -> result
    after
      5_000 -> flunk("Health.run never returned")
    end
  end

  defp await_hang(host, ref) do
    receive do
      {:hanging, ^host, ^ref, worker_pid} -> worker_pid
    after
      2_000 -> flunk("Stub checker never blocked for #{inspect(host)}")
    end
  end

  # TLA+ invariant: SettleDone — all hosts pass → phase = "done"
  test "all hosts passing → {:ok, all-passed outcomes}" do
    StubChecker.start_script(%{host_a: [:ok], host_b: [:ok]})

    targets = [
      {:host_a, [{:tcp, %{host: "x", port: 1}}]},
      {:host_b, [{:tcp, %{host: "x", port: 1}}]}
    ]

    assert {:ok, %{host_a: :passed, host_b: :passed}} =
             Health.run(targets, checker: StubChecker, max_retries: 0)
  end

  # TLA+ invariant: SettleFailed + ExhaustRetry
  test "one host failing past retry budget → {:error, :health_failed, ...}" do
    StubChecker.start_script(%{
      host_a: [:ok],
      # 1 initial + max_retries=2 → 3 attempts, all fail
      host_b: [{:error, :nope}, {:error, :nope}, {:error, :nope}]
    })

    targets = [
      {:host_a, [{:tcp, %{host: "x", port: 1}}]},
      {:host_b, [{:tcp, %{host: "x", port: 1}}]}
    ]

    assert {:error, :health_failed, outcomes} =
             Health.run(targets, checker: StubChecker, max_retries: 2)

    assert outcomes == %{host_a: :passed, host_b: :failed}
  end

  # TLA+ invariant: RetryBounded — passes if recovery happens within budget
  test "transient failure within retry budget → :passed" do
    StubChecker.start_script(%{host_a: [{:error, :flap}, {:error, :flap}, :ok]})

    targets = [{:host_a, [{:tcp, %{host: "x", port: 1}}]}]

    assert {:ok, %{host_a: :passed}} =
             Health.run(targets, checker: StubChecker, max_retries: 2)
  end

  # TLA+ invariant: RetryBounded — explicit budget exhaustion
  test "failure exactly at retry budget → :failed" do
    # 3 fails, then a :ok the executor must never reach (proves budget cap).
    StubChecker.start_script(%{
      host_a: [{:error, :nope}, {:error, :nope}, {:error, :nope}, :ok]
    })

    targets = [{:host_a, [{:tcp, %{host: "x", port: 1}}]}]

    assert {:error, :health_failed, %{host_a: :failed}} =
             Health.run(targets, checker: StubChecker, max_retries: 2)
  end

  # TLA+ invariant: NoLatePromotionAfterRollback (the critical race).
  #
  # The worker is blocked inside the checker. We latch rollback, then
  # release the checker with :ok. The host must NOT appear as :passed —
  # rollback wins because handle_cast({:check_complete, _, :passed}, ...)
  # reads rollback_signal in the same callback that records the outcome.
  test "late :passed after rollback signal does not promote host" do
    test_pid = self()
    ref = make_ref()

    StubChecker.start_script(%{host_a: [{:hang, ref, test_pid}]})

    targets = [{:host_a, [{:tcp, %{host: "x", port: 1}}]}]

    {_runner, health_pid} =
      start_health_async(targets, checker: StubChecker, max_retries: 0)

    worker = await_hang(:host_a, ref)

    # Latch rollback BEFORE the checker returns
    :ok = Health.signal_rollback(health_pid)

    # Now release the worker with :ok — it will cast {:check_complete, :passed}
    send(worker, {:release, ref, :ok})

    assert {:error, :rolled_back, %{host_a: :failed}} = await_result()
  end

  # TLA+ invariant: DrainAndFail — rollback with all checks in flight,
  # nil outcomes coerced to :failed by drain_for_rollback/1.
  test "rollback with all checks pending drains nil → :failed" do
    test_pid = self()
    ref_a = make_ref()
    ref_b = make_ref()

    StubChecker.start_script(%{
      host_a: [{:hang, ref_a, test_pid}],
      host_b: [{:hang, ref_b, test_pid}]
    })

    targets = [
      {:host_a, [{:tcp, %{host: "x", port: 1}}]},
      {:host_b, [{:tcp, %{host: "x", port: 1}}]}
    ]

    {_runner, health_pid} =
      start_health_async(targets, checker: StubChecker, max_retries: 0)

    worker_a = await_hang(:host_a, ref_a)
    worker_b = await_hang(:host_b, ref_b)

    :ok = Health.signal_rollback(health_pid)

    # Release both with :ok — they should STILL come back as :failed,
    # because rollback latched first.
    send(worker_a, {:release, ref_a, :ok})
    send(worker_b, {:release, ref_b, :ok})

    assert {:error, :rolled_back, %{host_a: :failed, host_b: :failed}} = await_result()
  end
end
