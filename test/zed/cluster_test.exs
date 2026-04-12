defmodule Zed.ClusterTest do
  use ExUnit.Case, async: true

  alias Zed.Cluster

  describe "Cluster module" do
    test "all_nodes returns list" do
      # In test environment, likely no other nodes
      nodes = Cluster.all_nodes()
      assert is_list(nodes)
    end

    test "nodes filters to agents only" do
      # Should return empty or filtered list
      nodes = Cluster.nodes()
      assert is_list(nodes)
    end

    test "connect to non-existent node returns error" do
      result = Cluster.connect(:"nonexistent@nowhere")

      # Either connection_failed or not_distributed (if not in distributed mode)
      assert match?({:error, _}, result)
    end

    test "ping non-existent node returns rpc error" do
      result = Cluster.ping(:"nonexistent@nowhere")

      assert {:error, {:rpc_failed, _, _}} = result
    end

    test "agent_running? returns false for non-existent node" do
      refute Cluster.agent_running?(:"nonexistent@nowhere")
    end
  end

  describe "multi-node operations" do
    test "converge_all with no nodes returns empty map" do
      ir = build_test_ir()

      # No nodes connected, should return empty
      result = Cluster.converge_all(ir)
      assert result == %{}
    end

    test "status_all with no nodes returns empty map" do
      ir = build_test_ir()

      result = Cluster.status_all(ir)
      assert result == %{}
    end

    test "diff_all with no nodes returns empty map" do
      ir = build_test_ir()

      result = Cluster.diff_all(ir)
      assert result == %{}
    end
  end

  # --- Helpers ---

  defp build_test_ir do
    %Zed.IR{
      name: :test_deploy,
      pool: "testpool",
      datasets: [],
      apps: [],
      jails: [],
      zones: [],
      clusters: [],
      snapshot_config: %{}
    }
  end
end
