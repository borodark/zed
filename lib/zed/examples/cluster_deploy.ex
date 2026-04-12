defmodule Zed.Examples.ClusterDeploy do
  @moduledoc """
  Example multi-host deployment.

  Demonstrates deploying the same app across multiple hosts
  with coordinated convergence and rollback.

  ## Prerequisites

  1. Start Erlang nodes with same cookie on each host:

      # Host 1 (controller)
      iex --name zed@host1.local --cookie secret -S mix

      # Host 2 (agent)
      iex --name zed@host2.local --cookie secret -S mix

  2. Start agents on each node:

      # On each node
      Zed.Agent.start_link()

  3. Connect from controller:

      Zed.Cluster.connect(:"zed@host2.local")

  ## Usage

      # Check all nodes
      Zed.Cluster.nodes()

      # Deploy to all
      ir = Zed.Examples.ClusterDeploy.__zed_ir__()
      Zed.Cluster.converge_all(ir)

      # Coordinated deploy with rollback on failure
      Zed.Cluster.converge_coordinated(ir)

      # Get status from all
      Zed.Cluster.status_all(ir)

  ## ZFS Replication

      # Sync dataset to remote (includes com.zed:* properties)
      Zed.ZFS.Replicate.sync_to_remote(
        "jeff/apps/trading",
        "root@host2.local",
        "tank/apps/trading"
      )
  """

  use Zed.DSL

  deploy :trading_cluster, pool: "jeff" do
    dataset "apps/trading" do
      compression :lz4
    end

    app :trading do
      dataset "apps/trading"
      version "1.0.0"
      node_name :"trading@localhost"
      cookie {:env, "RELEASE_COOKIE"}

      health :beam_ping, timeout: 5_000
    end

    snapshots do
      before_deploy true
      keep 5
    end
  end

end
