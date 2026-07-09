defmodule HelloBeam.Heartbeat do
  @moduledoc """
  Trivial GenServer that logs an "up" heartbeat every 30s.
  Purely there so the release has a supervised process to keep
  the BEAM alive.
  """

  use GenServer
  require Logger

  @tick_ms 30_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    schedule_tick()
    {:ok, %{ticks: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    Logger.info("hello_beam heartbeat tick=#{state.ticks}")
    schedule_tick()
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
