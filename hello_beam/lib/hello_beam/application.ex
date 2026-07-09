defmodule HelloBeam.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    require Logger
    Logger.info("HelloBeam booting: node=#{inspect(Node.self())} cookie=#{inspect(Node.get_cookie())}")

    children = [HelloBeam.Heartbeat]

    Supervisor.start_link(children, strategy: :one_for_one, name: HelloBeam.Supervisor)
  end
end
