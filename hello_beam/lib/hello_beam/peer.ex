defmodule HelloBeam.Peer do
  @moduledoc """
  Optional peer-connect worker for Path C4's two-node cluster smoke.

  If the `PEER_NODE` env var is set at boot, retries `Node.connect/1`
  every second until it returns `true` (which means `:pong`). Once
  connected, terminates — the peer is now in the local node's list
  and Erlang's distribution layer keeps the link alive.

  No-op when `PEER_NODE` is unset (single-node deploys via
  `Zed.Examples.SmokeContainedRealApp`). This mirrors the pattern
  used by libcluster's `Cluster.Strategy.Epmd` but without the
  dependency — hello_beam is a fixture, not a real app.
  """

  # `restart: :transient` — the supervisor won't restart when we
  # stop with :normal after a successful connect. Under the default
  # :permanent policy the peer would reconnect → stop → restart in a
  # tight loop, exhaust max_restarts, and take down the whole
  # application after ~5 seconds.
  use GenServer, restart: :transient
  require Logger

  @tick_ms 1_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    case System.get_env("PEER_NODE") do
      nil ->
        Logger.info("hello_beam peer: PEER_NODE unset, running solo")
        :ignore

      "" ->
        Logger.info("hello_beam peer: PEER_NODE empty, running solo")
        :ignore

      target ->
        peer = String.to_atom(target)
        Logger.info("hello_beam peer: will retry Node.connect(#{inspect(peer)})")
        schedule_tick()
        {:ok, %{peer: peer, attempts: 0}}
    end
  end

  @impl true
  def handle_info(:tick, %{peer: peer, attempts: n} = state) do
    if Node.connect(peer) do
      Logger.info("hello_beam peer: connected to #{inspect(peer)} after #{n + 1} attempts")
      {:stop, :normal, state}
    else
      schedule_tick()
      {:noreply, %{state | attempts: n + 1}}
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
