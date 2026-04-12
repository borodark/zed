defmodule Zed.Converge.IntegrationTest do
  @moduledoc """
  End-to-end convergence tests against real ZFS.

  Requires a delegated dataset. Set ZED_TEST_DATASET to run:

      ZED_TEST_DATASET=jeff/zed-test mix test --include zfs_live

  Skipped by default on machines without ZFS.
  """
  use ExUnit.Case

  alias Zed.ZFS
  alias Zed.ZFS.{Dataset, Property, Snapshot}

  @pool "jeff"
  @base_dataset "zed-test"
  @full_dataset "#{@pool}/#{@base_dataset}"

  # Tag all tests so they're excluded by default
  @moduletag :zfs_live

  setup do
    # Clean up any child datasets from prior runs
    child = "#{@full_dataset}/converge-test"
    if Dataset.exists?(child) do
      # Destroy snapshots first
      Snapshot.list(child)
      |> Enum.each(fn s -> Snapshot.destroy(s.name) end)
      ZFS.cmd(["destroy", "-r", child])
    end

    # Clean up com.zed:* properties from base dataset
    props = Property.get_all(@full_dataset)
    Enum.each(props, fn {key, _val} ->
      ZFS.cmd(["inherit", "com.zed:#{key}", @full_dataset])
    end)

    :ok
  end

  describe "converge with DSL" do
    test "creates dataset and stamps app properties" do
      # Define a simple deployment inline
      ir = %Zed.IR{
        name: :test_deploy,
        pool: @pool,
        datasets: [
          %Zed.IR.Node{
            id: "#{@base_dataset}/converge-test",
            type: :dataset,
            config: %{mountpoint: "/tmp/zed-converge-test", compression: :lz4}
          }
        ],
        apps: [
          %Zed.IR.Node{
            id: :testapp,
            type: :app,
            config: %{
              dataset: "#{@base_dataset}/converge-test",
              version: "1.0.0",
              node_name: :"testapp@localhost"
            },
            deps: ["#{@base_dataset}/converge-test"]
          }
        ],
        jails: [],
        zones: [],
        clusters: [],
        snapshot_config: %{before_deploy: false, keep: 5}
      }

      # Run converge - should create dataset and stamp properties
      # Using dry_run first to verify plan
      {:dry_run, plan} = Zed.Converge.run(ir, dry_run: true)

      # Should have: dataset create, app deploy, service install, service restart
      assert length(plan.steps) >= 2
      step_ids = Enum.map(plan.steps, & &1.id)
      assert "dataset:create:#{@base_dataset}/converge-test" in step_ids
      assert "app:deploy:testapp" in step_ids
    end

    test "diff detects version changes" do
      child = "#{@full_dataset}/converge-test"

      # Create dataset manually
      {:ok, _} = Dataset.create(child, %{"mountpoint" => "/tmp/zed-converge-test"})

      # Stamp initial version
      Property.set(child, "version", "1.0.0")
      Property.set(child, "app", "testapp")

      # Define IR with updated version
      ir = %Zed.IR{
        name: :test_deploy,
        pool: @pool,
        datasets: [
          %Zed.IR.Node{
            id: "#{@base_dataset}/converge-test",
            type: :dataset,
            config: %{mountpoint: "/tmp/zed-converge-test"}
          }
        ],
        apps: [
          %Zed.IR.Node{
            id: :testapp,
            type: :app,
            config: %{
              dataset: "#{@base_dataset}/converge-test",
              version: "2.0.0"
            },
            deps: ["#{@base_dataset}/converge-test"]
          }
        ],
        jails: [],
        zones: [],
        clusters: [],
        snapshot_config: %{before_deploy: false, keep: 5}
      }

      # Diff should detect version change
      diff = Zed.Converge.Diff.compute(ir)

      # Dataset should be noop (already exists), app should be update
      app_diff = Enum.find(diff, fn d -> d.resource.type == :app end)
      assert app_diff != nil
      assert app_diff.action == :update
      assert {:version, "1.0.0", "2.0.0"} in app_diff.changes
    end

    test "full converge creates dataset and stamps properties" do
      ir = %Zed.IR{
        name: :test_deploy,
        pool: @pool,
        datasets: [
          %Zed.IR.Node{
            id: "#{@base_dataset}/converge-test",
            type: :dataset,
            config: %{compression: :lz4}
          }
        ],
        apps: [
          %Zed.IR.Node{
            id: :testapp,
            type: :app,
            config: %{
              dataset: "#{@base_dataset}/converge-test",
              version: "1.0.0",
              node_name: :"testapp@localhost"
            },
            deps: ["#{@base_dataset}/converge-test"]
          }
        ],
        jails: [],
        zones: [],
        clusters: [],
        snapshot_config: %{before_deploy: false, keep: 5}
      }

      # Run converge - this will fail on service operations (no rc.d perms in test)
      # but dataset and property stamping should work
      result = Zed.Converge.run(ir)

      # Check dataset was created
      child = "#{@full_dataset}/converge-test"
      assert Dataset.exists?(child)

      # Check properties were stamped
      assert {:ok, "1.0.0"} = Property.get(child, "version")
      assert {:ok, "testapp"} = Property.get(child, "app")
      assert {:ok, "testapp@localhost"} = Property.get(child, "node_name")
      assert {:ok, "true"} = Property.get(child, "managed")

      # Verify compression was set
      {:ok, compression} = Dataset.get_property(child, "compression")
      assert compression == "lz4"

      # Result should be ok or error on service (depends on platform)
      case result do
        {:ok, _} -> :ok
        {:error, :step_failed, step, _reason} ->
          # Expected to fail on service step in test environment
          assert step.type == :service
      end
    end

    test "no changes when already converged" do
      child = "#{@full_dataset}/converge-test"

      # Create dataset (use inherited mountpoint) and stamp version
      {:ok, _} = Dataset.create(child, %{})
      Property.set(child, "version", "1.0.0")

      # IR without mountpoint config - won't trigger diff on mountpoint
      ir = %Zed.IR{
        name: :test_deploy,
        pool: @pool,
        datasets: [
          %Zed.IR.Node{
            id: "#{@base_dataset}/converge-test",
            type: :dataset,
            config: %{}
          }
        ],
        apps: [
          %Zed.IR.Node{
            id: :testapp,
            type: :app,
            config: %{
              dataset: "#{@base_dataset}/converge-test",
              version: "1.0.0"
            },
            deps: ["#{@base_dataset}/converge-test"]
          }
        ],
        jails: [],
        zones: [],
        clusters: [],
        snapshot_config: %{before_deploy: false, keep: 5}
      }

      # Should return no changes since state matches
      result = Zed.Converge.run(ir)
      assert result == {:ok, :no_changes}
    end
  end
end
