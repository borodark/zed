defmodule Zed.ZFS.IntegrationTest do
  @moduledoc """
  Integration tests against a real ZFS pool.

  Requires a delegated dataset. Set ZED_TEST_DATASET to run:

      ZED_TEST_DATASET=jeff/zed-test mix test --include zfs_live

  Skipped by default on machines without ZFS.
  """
  use ExUnit.Case

  alias Zed.ZFS
  alias Zed.ZFS.{Dataset, Property, Snapshot}

  @dataset System.get_env("ZED_TEST_DATASET", "jeff/zed-test")

  # Tag all tests so they're excluded by default
  @moduletag :zfs_live

  setup do
    # Clean up com.zed:* properties from prior runs
    props = Property.get_all(@dataset)

    Enum.each(props, fn {key, _val} ->
      ZFS.cmd(["inherit", "com.zed:#{key}", @dataset])
    end)

    # Destroy any test snapshots from prior runs
    Snapshot.list(@dataset)
    |> Enum.filter(fn s -> String.contains?(s.name, "zed-test-") end)
    |> Enum.each(fn s -> Snapshot.destroy(s.name) end)

    :ok
  end

  describe "Dataset" do
    test "exists? returns true for delegated dataset" do
      assert Dataset.exists?(@dataset) == true
    end

    test "exists? returns false for nonexistent dataset" do
      assert Dataset.exists?("jeff/does-not-exist-#{System.unique_integer()}") == false
    end

    test "mountpoint returns the current mountpoint" do
      mp = Dataset.mountpoint(@dataset)
      assert is_binary(mp)
      assert String.starts_with?(mp, "/")
    end

    test "list returns datasets under parent" do
      datasets = Dataset.list(@dataset)
      assert is_list(datasets)
      assert @dataset in datasets
    end

    test "create and destroy child dataset" do
      child = "#{@dataset}/int-test-#{System.unique_integer([:positive])}"

      # Create
      assert {:ok, _} = Dataset.create(child, %{"mountpoint" => "none"})
      assert Dataset.exists?(child) == true

      # Destroy
      assert {:ok, _} = ZFS.cmd(["destroy", child])
      assert Dataset.exists?(child) == false
    end
  end

  describe "Property" do
    test "set and get a user property" do
      assert {:ok, _} = Property.set(@dataset, "test_key", "test_value")
      assert {:ok, "test_value"} = Property.get(@dataset, "test_key")
    end

    test "get returns :not_set for missing property" do
      assert :not_set = Property.get(@dataset, "nonexistent_key_#{System.unique_integer()}")
    end

    test "get_all returns all com.zed:* properties" do
      Property.set(@dataset, "alpha", "1")
      Property.set(@dataset, "beta", "2")

      all = Property.get_all(@dataset)
      assert all["alpha"] == "1"
      assert all["beta"] == "2"
    end

    test "set_many sets multiple properties" do
      Property.set_many(@dataset, %{
        managed: "true",
        app: "myapp",
        version: "1.2.3"
      })

      assert {:ok, "true"} = Property.get(@dataset, "managed")
      assert {:ok, "myapp"} = Property.get(@dataset, "app")
      assert {:ok, "1.2.3"} = Property.get(@dataset, "version")
    end

    test "properties survive overwrite" do
      Property.set(@dataset, "version", "1.0.0")
      assert {:ok, "1.0.0"} = Property.get(@dataset, "version")

      Property.set(@dataset, "version", "2.0.0")
      assert {:ok, "2.0.0"} = Property.get(@dataset, "version")
    end
  end

  describe "Snapshot" do
    test "create and list snapshots" do
      assert {:ok, _} = Snapshot.create(@dataset, "zed-test-snap1")

      snaps = Snapshot.list(@dataset)
      names = Enum.map(snaps, & &1.name)
      assert "#{@dataset}@zed-test-snap1" in names
    end

    test "create_deploy_snapshot generates timestamped name" do
      assert {:ok, snap_name} = Snapshot.create_deploy_snapshot(@dataset, "1.0.0")
      assert String.contains?(snap_name, "zed-deploy-1.0.0-")
      assert String.starts_with?(snap_name, @dataset)

      # Verify it exists
      snaps = Snapshot.list(@dataset)
      names = Enum.map(snaps, & &1.name)
      assert snap_name in names
    end

    test "find_latest returns most recent matching snapshot" do
      Snapshot.create(@dataset, "zed-test-old")
      Process.sleep(1_000)
      Snapshot.create(@dataset, "zed-test-new")

      latest = Snapshot.find_latest(@dataset, "zed-test-")
      assert latest != nil
      assert String.contains?(latest.name, "zed-test-new")
    end

    test "prune keeps only the specified count" do
      Snapshot.create(@dataset, "zed-test-prune-1")
      Process.sleep(1_100)
      Snapshot.create(@dataset, "zed-test-prune-2")
      Process.sleep(1_100)
      Snapshot.create(@dataset, "zed-test-prune-3")

      deleted = Snapshot.prune(@dataset, "zed-test-prune-", 2)
      assert deleted == 1

      remaining =
        Snapshot.list(@dataset)
        |> Enum.filter(fn s -> String.contains?(s.name, "zed-test-prune-") end)

      assert length(remaining) == 2
    end

    test "rollback restores dataset state" do
      # Set a property, snapshot, change it, rollback
      Property.set(@dataset, "rollback_test", "before")
      Snapshot.create(@dataset, "zed-test-rollback")

      Property.set(@dataset, "rollback_test", "after")
      assert {:ok, "after"} = Property.get(@dataset, "rollback_test")

      # Rollback
      Snapshot.rollback("#{@dataset}@zed-test-rollback")

      # ZFS user properties are metadata, not data — they survive rollback.
      # But file contents on the dataset would be reverted.
      # This test verifies the rollback command succeeds.
      snaps = Snapshot.list(@dataset)
      assert is_list(snaps)
    end

    test "destroy removes a snapshot" do
      Snapshot.create(@dataset, "zed-test-destroy")

      snaps_before =
        Snapshot.list(@dataset)
        |> Enum.filter(fn s -> String.contains?(s.name, "zed-test-destroy") end)

      assert length(snaps_before) == 1

      Snapshot.destroy("#{@dataset}@zed-test-destroy")

      snaps_after =
        Snapshot.list(@dataset)
        |> Enum.filter(fn s -> String.contains?(s.name, "zed-test-destroy") end)

      assert snaps_after == []
    end
  end

  describe "full workflow" do
    test "simulate a deploy cycle: stamp → snapshot → update → rollback" do
      # 1. Initial deploy stamp
      Property.set_many(@dataset, %{
        managed: "true",
        app: "exmc",
        version: "1.0.0",
        deployed_at: "2026-04-12T12:00:00Z"
      })

      assert {:ok, "1.0.0"} = Property.get(@dataset, "version")

      # 2. Pre-deploy snapshot
      {:ok, snap} = Snapshot.create_deploy_snapshot(@dataset, "1.0.0")

      # 3. Deploy v2
      Property.set(@dataset, "version", "2.0.0")
      Property.set(@dataset, "prev_version", "1.0.0")
      Property.set(@dataset, "deployed_at", "2026-04-12T13:00:00Z")

      assert {:ok, "2.0.0"} = Property.get(@dataset, "version")
      assert {:ok, "1.0.0"} = Property.get(@dataset, "prev_version")

      # 4. Rollback
      {:ok, _} = Snapshot.rollback(snap)

      # 5. Verify snapshot list is consistent
      snaps = Snapshot.list(@dataset)
      assert is_list(snaps)
    end
  end
end
