defmodule Zed.Converge.PlanTest do
  use ExUnit.Case, async: true

  alias Zed.Converge.{Diff, Plan}
  alias Zed.IR.Node

  describe "plan from diff" do
    test "dataset create produces create step" do
      diff = [
        %Diff{
          resource: %Node{id: "apps/web", type: :dataset, config: %{mountpoint: "/opt/web", compression: :lz4}},
          action: :create,
          current: nil,
          desired: %{mountpoint: "/opt/web", compression: :lz4},
          changes: [{:exists, false, true}]
        }
      ]

      plan = Plan.from_diff(diff)
      assert length(plan.steps) == 1
      [step] = plan.steps
      assert step.type == :dataset
      assert step.action == :create
      assert step.args.path == "apps/web"
      assert step.args.properties["mountpoint"] == "/opt/web"
    end

    test "app update produces deploy + install + restart steps" do
      diff = [
        %Diff{
          resource: %Node{
            id: :web,
            type: :app,
            config: %{version: "2.0.0", dataset: "apps/web", service: "web"}
          },
          action: :update,
          current: %{version: "1.0.0"},
          desired: %{version: "2.0.0"},
          changes: [{:version, "1.0.0", "2.0.0"}]
        }
      ]

      plan = Plan.from_diff(diff)
      # app:deploy, service:install, service:restart
      assert length(plan.steps) == 3

      types = Enum.map(plan.steps, & &1.type)
      assert :app in types
      assert :service in types

      actions = Enum.map(plan.steps, & &1.action)
      assert :install in actions
      assert :restart in actions
    end

    test "steps are sorted: datasets before apps before services" do
      diff = [
        %Diff{
          resource: %Node{id: :web, type: :app, config: %{version: "1.0.0", dataset: "apps/web"}},
          action: :create,
          changes: [{:version, nil, "1.0.0"}]
        },
        %Diff{
          resource: %Node{id: "apps/web", type: :dataset, config: %{mountpoint: "/opt/web"}},
          action: :create,
          changes: [{:exists, false, true}]
        }
      ]

      plan = Plan.from_diff(diff)
      types = Enum.map(plan.steps, & &1.type)

      ds_idx = Enum.find_index(types, &(&1 == :dataset))
      app_idx = Enum.find_index(types, &(&1 == :app))
      svc_idx = Enum.find_index(types, &(&1 == :service))

      assert ds_idx < app_idx
      assert app_idx < svc_idx
    end

    test "dry_run flag propagates" do
      plan = Plan.from_diff([], dry_run: true)
      assert plan.dry_run == true
    end
  end
end
