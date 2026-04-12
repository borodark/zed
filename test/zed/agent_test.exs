defmodule Zed.AgentTest do
  use ExUnit.Case, async: false

  alias Zed.Agent

  setup do
    # Start agent for tests
    {:ok, pid} = Agent.start_link(name: :test_agent, platform: Zed.Platform.Linux)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{agent: pid}
  end

  describe "Agent GenServer" do
    test "starts and responds to ping" do
      assert {:pong, _node} = GenServer.call(:test_agent, :ping)
    end

    test "returns agent info" do
      info = GenServer.call(:test_agent, :info)

      assert is_atom(info.node)
      assert info.platform == Zed.Platform.Linux
      assert info.deployments == %{}
    end

    test "handles diff request" do
      ir = build_test_ir()

      # Diff won't find datasets (they don't exist), so should return create actions
      result = GenServer.call(:test_agent, {:diff, ir})

      assert is_list(result)
    end

    test "handles converge dry_run" do
      ir = build_test_ir()

      result = GenServer.call(:test_agent, {:converge, ir, [dry_run: true]})

      assert {:dry_run, plan} = result
      assert length(plan.steps) > 0
    end

    test "tracks deployments after converge" do
      ir = build_test_ir()

      _result = GenServer.call(:test_agent, {:converge, ir, [dry_run: true]})

      info = GenServer.call(:test_agent, :info)
      assert Map.has_key?(info.deployments, :test_deploy)
      assert info.deployments[:test_deploy].result == :dry_run
    end
  end

  # --- Helpers ---

  defp build_test_ir do
    %Zed.IR{
      name: :test_deploy,
      pool: "testpool",
      datasets: [
        %Zed.IR.Node{
          id: "apps/test",
          type: :dataset,
          config: %{compression: :lz4}
        }
      ],
      apps: [
        %Zed.IR.Node{
          id: :testapp,
          type: :app,
          config: %{
            dataset: "apps/test",
            version: "1.0.0"
          },
          deps: ["apps/test"]
        }
      ],
      jails: [],
      zones: [],
      clusters: [],
      snapshot_config: %{before_deploy: false, keep: 5}
    }
  end
end
