defmodule HelloBeam.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    require Logger

    Logger.info(
      "HelloBeam booting: node=#{inspect(Node.self())} cookie=#{inspect(Node.get_cookie())}"
    )

    # Path C5: when libcluster has a topology configured (from
    # runtime.exs reading Zed's cluster artifact), supervise
    # Cluster.Supervisor. When empty (dev / no cluster mount), skip
    # the supervisor entirely and fall back to HelloBeam.Peer for
    # the C4 single-peer path.
    topologies = Application.get_env(:libcluster, :topologies, [])

    cluster_children =
      case topologies do
        [] ->
          Logger.info("HelloBeam: no libcluster topology, using HelloBeam.Peer fallback")
          [HelloBeam.Peer]

        _ ->
          Logger.info("HelloBeam: libcluster topology configured: #{inspect(topologies)}")
          [{Cluster.Supervisor, [topologies, [name: HelloBeam.ClusterSupervisor]]}]
      end

    children = [HelloBeam.Heartbeat | cluster_children]

    Supervisor.start_link(children, strategy: :one_for_one, name: HelloBeam.Supervisor)
  end
end
