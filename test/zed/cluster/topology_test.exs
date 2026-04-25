defmodule Zed.Cluster.TopologyTest do
  use ExUnit.Case, async: true

  alias Zed.Cluster.Topology
  alias Zed.IR
  alias Zed.IR.Node

  defp ir(clusters) do
    %IR{
      name: :test,
      pool: "tank",
      datasets: [],
      apps: [],
      jails: [],
      zones: [],
      clusters: clusters,
      snapshot_config: %{}
    }
  end

  defp cluster(id, opts) do
    %Node{id: id, type: :cluster, config: Map.new(opts), deps: []}
  end

  describe "from_ir/1" do
    test "empty IR returns empty map" do
      assert %{} = Topology.from_ir(ir([]))
    end

    test "single cluster renders to libcluster :static_topology shape" do
      result =
        ir([
          cluster(:demo,
            cookie: {:secret, :demo_cluster_cookie, :value},
            members: [:"web@10.0.0.1", :"worker@10.0.0.2"]
          )
        ])
        |> Topology.from_ir()

      assert %{
               demo: [
                 strategy: Cluster.Strategy.Epmd,
                 config: [hosts: [:"web@10.0.0.1", :"worker@10.0.0.2"]]
               ]
             } = result
    end

    test "missing :members defaults to empty hosts" do
      result =
        ir([cluster(:demo, cookie: {:env, "COOKIE"})])
        |> Topology.from_ir()

      assert %{demo: [strategy: _, config: [hosts: []]]} = result
    end

    test "two clusters preserve both" do
      result =
        ir([
          cluster(:web, cookie: {:env, "C1"}, members: [:"a@h1"]),
          cluster(:bg, cookie: {:env, "C2"}, members: [:"b@h2"])
        ])
        |> Topology.from_ir()

      assert Map.has_key?(result, :web)
      assert Map.has_key?(result, :bg)
    end
  end

  describe "cookie_ref/2" do
    test "returns the unresolved {:secret, ...} ref" do
      ref = {:secret, :demo_cluster_cookie, :value}

      assert ^ref =
               ir([cluster(:demo, cookie: ref, members: [])])
               |> Topology.cookie_ref(:demo)
    end

    test "returns the unresolved {:env, ...} ref" do
      ref = {:env, "COOKIE"}

      assert ^ref =
               ir([cluster(:demo, cookie: ref, members: [])])
               |> Topology.cookie_ref(:demo)
    end

    test "nil for unknown cluster id" do
      assert nil ==
               ir([cluster(:demo, cookie: {:env, "X"}, members: [])])
               |> Topology.cookie_ref(:other)
    end

    test "nil when cluster declares no cookie" do
      assert nil ==
               ir([cluster(:demo, members: [])])
               |> Topology.cookie_ref(:demo)
    end
  end
end
