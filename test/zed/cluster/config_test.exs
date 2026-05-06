defmodule Zed.Cluster.ConfigTest do
  use ExUnit.Case, async: true

  alias Zed.Cluster.Config
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

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "zed-cluster-config-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit_rm(path)
    path
  end

  defp on_exit_rm(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
  end

  describe "write!/3 + load!/1 round-trip" do
    test "writes one file per cluster as plain text and loads host atoms back" do
      base = tmp_dir()

      result =
        ir([
          cluster(:demo,
            cookie: {:env, "C"},
            members: [:"web@10.0.0.1", :"worker@10.0.0.2"]
          ),
          cluster(:bg,
            cookie: {:env, "C"},
            members: [:"job@10.0.0.3"]
          )
        ])
        |> Config.write!(base)

      assert {:ok, paths} = result
      assert length(paths) == 2

      demo_path = Enum.find(paths, &String.ends_with?(&1, "demo.config"))
      bg_path = Enum.find(paths, &String.ends_with?(&1, "bg.config"))

      # File contents are plain text — universally consumable.
      assert File.read!(demo_path) == "web@10.0.0.1\nworker@10.0.0.2\n"
      assert File.read!(bg_path) == "job@10.0.0.3\n"

      # load!/1 returns the host atoms directly.
      assert Config.load!(demo_path) == [:"web@10.0.0.1", :"worker@10.0.0.2"]
      assert Config.load!(bg_path) == [:"job@10.0.0.3"]

      # topology!/1 wraps in the libcluster Epmd shape.
      assert Config.topology!(demo_path) == [
               strategy: Cluster.Strategy.Epmd,
               config: [hosts: [:"web@10.0.0.1", :"worker@10.0.0.2"]]
             ]
    end

    test "no clusters → empty file list" do
      base = tmp_dir()
      assert {:ok, []} = Config.write!(ir([]), base)
    end

    test "creates the cluster subdir if missing" do
      base = tmp_dir()
      File.rm_rf!(Path.join(base, "cluster"))

      assert {:ok, [_]} =
               ir([cluster(:demo, cookie: {:env, "C"}, members: [:"a@h"])])
               |> Config.write!(base)

      assert File.dir?(Path.join(base, "cluster"))
    end

    test "second write replaces the first atomically (no .tmp leftover)" do
      base = tmp_dir()
      i = ir([cluster(:demo, cookie: {:env, "C"}, members: [:"a@h"])])

      {:ok, [path]} = Config.write!(i, base)
      {:ok, [^path]} = Config.write!(i, base)

      tmps =
        path
        |> Path.dirname()
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, ".tmp."))

      assert tmps == []
    end

    test "subdir override puts files where requested" do
      base = tmp_dir()
      override = Path.join(base, "custom-cluster-dir")

      {:ok, [path]} =
        ir([cluster(:demo, cookie: {:env, "C"}, members: [:"a@h"])])
        |> Config.write!(base, subdir: override)

      assert String.starts_with?(path, override)
    end
  end

  describe "load!/1" do
    test "raises if the file is missing" do
      assert_raise File.Error, fn -> Config.load!("/nonexistent/cluster.config") end
    end

    test "tolerates blank lines and # comments" do
      base = tmp_dir()
      path = Path.join(base, "annotated.config")
      File.write!(path, """
      # demo cluster — five nodes
      web@10.0.0.1

      # workers
      worker@10.0.0.2
      worker@10.0.0.3

      """)

      assert Config.load!(path) ==
               [:"web@10.0.0.1", :"worker@10.0.0.2", :"worker@10.0.0.3"]
    end

    test "rejects malformed lines (no @ separator)" do
      base = tmp_dir()
      bad = Path.join(base, "bad.config")
      File.write!(bad, "garbage_no_at_sign\n")

      assert_raise ArgumentError, ~r/not a valid node atom/, fn -> Config.load!(bad) end
    end

    test "rejects empty name half" do
      base = tmp_dir()
      bad = Path.join(base, "bad.config")
      File.write!(bad, "@host\n")

      assert_raise ArgumentError, ~r/not a valid node atom/, fn -> Config.load!(bad) end
    end

    test "rejects empty host half" do
      base = tmp_dir()
      bad = Path.join(base, "bad.config")
      File.write!(bad, "name@\n")

      assert_raise ArgumentError, ~r/not a valid node atom/, fn -> Config.load!(bad) end
    end
  end

  describe "read_cookie!/1" do
    test "{:file, path} reads and trims trailing newline" do
      base = tmp_dir()
      path = Path.join(base, "cookie")
      File.write!(path, "secret-cookie-value\n")

      assert "secret-cookie-value" == Config.read_cookie!({:file, path})
    end

    test "{:file, path} preserves internal newlines" do
      base = tmp_dir()
      path = Path.join(base, "cookie")
      File.write!(path, "line1\nline2\n")

      assert "line1\nline2" == Config.read_cookie!({:file, path})
    end

    test "{:env, var} reads the env var" do
      System.put_env("ZED_TEST_COOKIE_VAR", "from-env")
      on_exit(fn -> System.delete_env("ZED_TEST_COOKIE_VAR") end)

      assert "from-env" == Config.read_cookie!({:env, "ZED_TEST_COOKIE_VAR"})
    end

    test "{:env, var} raises when unset" do
      System.delete_env("ZED_TEST_COOKIE_VAR_UNSET")

      assert_raise RuntimeError, ~r/env var "ZED_TEST_COOKIE_VAR_UNSET" unset/, fn ->
        Config.read_cookie!({:env, "ZED_TEST_COOKIE_VAR_UNSET"})
      end
    end

    test "raw binary passes through" do
      assert "literal-cookie" == Config.read_cookie!("literal-cookie")
    end

    test "{:secret, ...} ref is rejected (must be resolved before runtime)" do
      assert_raise ArgumentError, ~r/unexpected ref/, fn ->
        Config.read_cookie!({:secret, :demo_cluster_cookie, :value})
      end
    end
  end
end
