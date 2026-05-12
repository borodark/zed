defmodule Zed.Converge.Health do
  @moduledoc """
  Health-check sub-protocol for coordinated converge.

  Implementation of `specs/HealthCheck.tla`. Invoked from `Zed.Cluster`
  after a successful multi-host converge, before the protocol declares
  `:ok`. Each host runs its configured `health` checks (`:http`,
  `:beam_ping`, custom callbacks). Failed or timed-out checks may
  retry up to `:max_retries`. Once every host settles, the protocol
  resolves to `{:ok, outcomes}` (all passed) or
  `{:error, :health_failed, outcomes}` (any failed).

  ## Composition with rollback

  An external rollback signal — operator abort, upstream failure, a
  peer-host's converge failing — can latch via `signal_rollback/1`
  while checks are in flight. The TLA+ invariant
  `NoLatePromotionAfterRollback` is realised here by routing every
  per-worker outcome through this GenServer's serialised state: the
  `:passed` write checks the rollback flag in the same callback that
  records the final outcome, so a slow `200 OK` arriving after the
  flag latched cannot promote the host.

  ## Targets

      [
        {:host_a, [
          {:http, %{url: "http://10.0.1.10:4000/health", expect: 200}},
          {:beam_ping, %{node: :"app@10.0.1.10", timeout: 5_000}}
        ]},
        {:host_b, [...]}
      ]
  """

  use GenServer
  require Logger

  @type host :: term()
  @type check_spec :: {atom(), map()}
  @type outcome :: :passed | :failed
  @type result ::
          {:ok, %{host => :passed}}
          | {:error, :health_failed, %{host => outcome}}
          | {:error, :rolled_back, %{host => outcome}}

  @default_max_retries 2
  @default_check_timeout 5_000
  @default_run_timeout 60_000

  @doc """
  Run health checks against `targets` and block until they all settle.

  Options:
    * `:max_retries`     — per-host retry budget (default 2)
    * `:check_timeout`   — per-check wall-clock cap in ms (default 5_000)
    * `:run_timeout`     — outer timeout for the whole protocol (default 60_000)
    * `:checker`         — module implementing `Zed.Converge.Health.Checker`
                           (default `Zed.Converge.Health.DefaultChecker`)
    * `:on_start`        — optional `(pid -> any())` callback invoked once
                           the orchestrator is spawned. Lets tests grab
                           the pid so they can drive `signal_rollback/1`
                           mid-flight. Not used in production paths.
  """
  @spec run([{host, [check_spec]}], keyword()) :: result()
  def run(targets, opts \\ []) when is_list(targets) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {targets, opts, self()})

    case Keyword.get(opts, :on_start) do
      nil -> :ok
      fun when is_function(fun, 1) -> fun.(pid)
    end

    run_timeout = Keyword.get(opts, :run_timeout, @default_run_timeout)

    receive do
      {:health_result, ^pid, result} -> result
    after
      run_timeout ->
        :ok = GenServer.stop(pid, :timeout)
        {:error, :health_failed, %{}}
    end
  end

  @doc "Latch the external-rollback signal for an in-flight protocol."
  @spec signal_rollback(GenServer.server()) :: :ok
  def signal_rollback(pid), do: GenServer.cast(pid, :rollback_signal)

  # --- GenServer ---

  @impl true
  def init({targets, opts, waiter}) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    check_timeout = Keyword.get(opts, :check_timeout, @default_check_timeout)
    checker = Keyword.get(opts, :checker, Zed.Converge.Health.DefaultChecker)

    hosts = Enum.map(targets, &elem(&1, 0))

    state = %{
      waiter: waiter,
      checker: checker,
      max_retries: max_retries,
      check_timeout: check_timeout,
      final_outcome: Map.new(hosts, &{&1, nil}),
      pending: MapSet.new(hosts),
      rollback_signal: false
    }

    Enum.each(targets, fn {host, checks} ->
      spawn_worker(self(), host, checks, max_retries, check_timeout, checker)
    end)

    {:ok, state}
  end

  @impl true
  def handle_cast(:rollback_signal, state) do
    Logger.info("[Health] external rollback signal latched")
    state = %{state | rollback_signal: true}
    maybe_finish(state)
  end

  @impl true
  def handle_cast({:check_complete, host, :passed}, state) do
    # NoLatePromotionAfterRollback: read rollback_signal in the same
    # callback that records the outcome.
    state =
      if state.rollback_signal do
        state
      else
        record_outcome(state, host, :passed)
      end

    state = drop_pending(state, host)
    maybe_finish(state)
  end

  def handle_cast({:check_complete, host, :failed}, state) do
    state = state |> record_outcome(host, :failed) |> drop_pending(host)
    maybe_finish(state)
  end

  # --- internal ---

  defp record_outcome(state, host, outcome) do
    case state.final_outcome[host] do
      nil -> %{state | final_outcome: Map.put(state.final_outcome, host, outcome)}
      _settled -> state
    end
  end

  defp drop_pending(state, host),
    do: %{state | pending: MapSet.delete(state.pending, host)}

  defp maybe_finish(state) do
    cond do
      MapSet.size(state.pending) > 0 ->
        {:noreply, state}

      state.rollback_signal ->
        outcomes = drain_for_rollback(state.final_outcome)
        send(state.waiter, {:health_result, self(), {:error, :rolled_back, outcomes}})
        {:stop, :normal, state}

      Enum.all?(state.final_outcome, fn {_, o} -> o == :passed end) ->
        send(state.waiter, {:health_result, self(), {:ok, state.final_outcome}})
        {:stop, :normal, state}

      true ->
        send(state.waiter, {:health_result, self(), {:error, :health_failed, state.final_outcome}})
        {:stop, :normal, state}
    end
  end

  defp drain_for_rollback(outcomes) do
    Map.new(outcomes, fn
      {h, nil} -> {h, :failed}
      {h, o} -> {h, o}
    end)
  end

  defp spawn_worker(parent, host, checks, max_retries, check_timeout, checker) do
    Task.start(fn ->
      outcome = run_with_retries(host, checks, 0, max_retries, check_timeout, checker)
      GenServer.cast(parent, {:check_complete, host, outcome})
    end)
  end

  defp run_with_retries(host, checks, attempt, max, timeout, checker) do
    case run_one_round(host, checks, timeout, checker) do
      :passed ->
        :passed

      {:failed, reason} when attempt < max ->
        Logger.warning(
          "[Health] #{inspect(host)} attempt #{attempt + 1} failed: #{inspect(reason)}, retrying"
        )

        run_with_retries(host, checks, attempt + 1, max, timeout, checker)

      {:failed, reason} ->
        Logger.error("[Health] #{inspect(host)} retries exhausted: #{inspect(reason)}")
        :failed
    end
  end

  defp run_one_round(host, checks, timeout, checker) do
    Enum.reduce_while(checks, :passed, fn {type, opts}, _ ->
      case checker.check(host, type, opts, timeout) do
        :ok -> {:cont, :passed}
        {:error, reason} -> {:halt, {:failed, reason}}
      end
    end)
  end
end
