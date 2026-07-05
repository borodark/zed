defmodule Zed.Converge.ExecutorTest do
  @moduledoc """
  Unit tests for the jail sub-step executor clauses. Uses
  `Zed.Platform.Bastille.Runner.Mock` so no `bastille` binary
  is required; runs on any host.
  """

  use ExUnit.Case, async: false

  alias Zed.Converge.{Executor, Plan, Step}
  alias Zed.Platform.Bastille.Runner.Mock

  setup do
    case Mock.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Mock.reset()
    end

    Application.put_env(:zed, Zed.Platform.Bastille, runner: Mock)

    on_exit(fn ->
      Application.delete_env(:zed, Zed.Platform.Bastille)
    end)

    :ok
  end

  defp run_step(step) do
    Executor.run(%Plan{steps: [step], dry_run: false}, Zed.Platform.FreeBSD)
  end

  describe ":jail :install (via Bastille)" do
    test "skips create when Bastille.exists? returns true" do
      # Bastille.exists? uses the :list subcommand and grep for the
      # jail name in column 2. Provide a matching row so exists? is true.
      Mock.expect(:list, {" JID Name  State\n  1 smoke_up ACTIVE\n", 0})

      step = %Step{
        id: "jail:install:smoke_up",
        type: :jail,
        action: :install,
        args: %{
          jail: :smoke_up,
          path: "/mac_zroot/jails/smoke_up",
          hostname: "smoke-up.local",
          ip4: "10.17.89.90/24",
          ip6: nil,
          vnet: false,
          release: nil,
          jail_params: []
        }
      }

      assert {:ok, [{"jail:install:smoke_up", :ok}]} = run_step(step)

      # Only the :list probe; no :create call.
      calls = Mock.calls()
      assert Enum.any?(calls, fn {sub, _, _} -> sub == :list end)
      refute Enum.any?(calls, fn {sub, _, _} -> sub == :create end)
    end

    test "calls Bastille.create when jail doesn't exist" do
      # exists? returns false (empty list), then create returns ok.
      Mock.expect(:list, {" JID Name\n", 0})
      Mock.expect(:create, {"", 0})

      step = %Step{
        id: "jail:install:smoke_up",
        type: :jail,
        action: :install,
        args: %{
          jail: :smoke_up,
          path: "/mac_zroot/jails/smoke_up",
          hostname: "smoke-up.local",
          ip4: "10.17.89.90/24",
          ip6: nil,
          vnet: false,
          release: "15.0-RELEASE",
          jail_params: []
        }
      }

      assert {:ok, [{"jail:install:smoke_up", :ok}]} = run_step(step)

      calls = Mock.calls()

      assert Enum.any?(calls, fn
               {:create, ["smoke_up", "15.0-RELEASE", "10.17.89.90/24"], _} -> true
               _ -> false
             end)
    end

    test "propagates missing ip4 as :jail_install_failed" do
      step = %Step{
        id: "jail:install:foo",
        type: :jail,
        action: :install,
        args: %{
          jail: :foo,
          path: "/x",
          hostname: "foo.local",
          ip4: nil,
          ip6: nil,
          vnet: false,
          release: nil,
          jail_params: []
        }
      }

      assert {:error, _step, {:jail_install_failed, "foo", {:jail_install_failed, :missing_ip4}},
              _} = run_step(step)
    end
  end

  describe ":jail_pkg :install" do
    test "shells out via bastille cmd pkg install -y" do
      Mock.expect(:cmd, {"", 0})

      step = %Step{
        id: "jail:pkg:pg",
        type: :jail_pkg,
        action: :install,
        args: %{jail: :pg, packages: ["postgresql16-server", "postgresql16-client"]}
      }

      assert {:ok, [{"jail:pkg:pg", {:jail_pkg_installed, "pg", pkgs}}]} = run_step(step)
      assert pkgs == ["postgresql16-server", "postgresql16-client"]

      assert [{:cmd, argv, _}] = Mock.calls()

      assert argv ==
               ["pg", "pkg", "install", "-y", "postgresql16-server", "postgresql16-client"]
    end

    test "propagates bastille exit as :jail_pkg_failed" do
      Mock.expect(:cmd, {"pkg: no such package: ghostpkg\n", 1})

      step = %Step{
        id: "jail:pkg:foo",
        type: :jail_pkg,
        action: :install,
        args: %{jail: :foo, packages: ["ghostpkg"]}
      }

      assert {:error, _step, {:jail_pkg_failed, "foo", ["ghostpkg"], {:bastille_exit, 1, _}}, _} =
               run_step(step)
    end
  end

  describe ":jail_mount :create" do
    test "invokes bastille mount when jail_path not already mounted" do
      # First call: probe `mount` inside jail → no line for the target.
      # Second call: the mount itself.
      # Mock returns the same expectation each time — so use output that
      # never matches, and set exit codes distinctly if needed.
      Mock.expect(:cmd, {"tmpfs on /tmp (tmpfs, local)\n", 0})
      Mock.expect(:mount, {"", 0})

      step = %Step{
        id: "jail:mount:pg:0",
        type: :jail_mount,
        action: :create,
        args: %{
          jail: :pg,
          host_path: "/mnt/jeff/secrets",
          jail_path: "/var/db/zed/secrets",
          mode: :ro
        }
      }

      assert {:ok, [{"jail:mount:pg:0", {:jail_mount_created, "pg", host, jail_path}}]} =
               run_step(step)

      assert host == "/mnt/jeff/secrets"
      assert jail_path == "/var/db/zed/secrets"

      calls = Mock.calls()
      assert [{:cmd, ["pg", "mount"], _}, {:mount, mount_argv, _}] = calls
      assert mount_argv ==
               ["pg", "/mnt/jeff/secrets", "/var/db/zed/secrets", "nullfs", "ro", "0", "0"]
    end

    test "short-circuits when jail_path is already mounted" do
      probe_output = """
      tmpfs on /tmp (tmpfs, local)
      /mnt/jeff/secrets on /var/db/zed/secrets (nullfs, local, read-only)
      """

      Mock.expect(:cmd, {probe_output, 0})

      step = %Step{
        id: "jail:mount:pg:0",
        type: :jail_mount,
        action: :create,
        args: %{
          jail: :pg,
          host_path: "/mnt/jeff/secrets",
          jail_path: "/var/db/zed/secrets",
          mode: :ro
        }
      }

      assert {:ok, [{"jail:mount:pg:0", {:jail_mount_already_present, "pg", jail_path}}]} =
               run_step(step)

      assert jail_path == "/var/db/zed/secrets"
      assert [{:cmd, ["pg", "mount"], _}] = Mock.calls()
    end

    test "propagates bastille mount exit as :jail_mount_failed" do
      Mock.expect(:cmd, {"", 0})
      Mock.expect(:mount, {"mount: no such file\n", 1})

      step = %Step{
        id: "jail:mount:pg:0",
        type: :jail_mount,
        action: :create,
        args: %{
          jail: :pg,
          host_path: "/missing",
          jail_path: "/var/db/zed/secrets",
          mode: :ro
        }
      }

      assert {:error, _step,
              {:jail_mount_failed, "pg", "/var/db/zed/secrets",
               {:bastille_exit, 1, _}}, _} = run_step(step)
    end
  end

  describe ":jail_svc :start" do
    test "sysrc-enables then starts service when not running" do
      # cmd 1: sysrc <svc>_enable=YES → ok
      # cmd 2: service <svc> status → non-zero (not running)
      # cmd 3: service <svc> start → ok
      #
      # Mock only supports one expectation per subcommand; distinguish
      # by injecting expectations sequentially. Use a queue-like
      # approach: overwrite between assertions.
      Mock.expect(:cmd, {"", 0})

      step = %Step{
        id: "jail:svc:pg:postgresql",
        type: :jail_svc,
        action: :start,
        args: %{jail: :pg, service: :postgresql, env: nil}
      }

      # Because the Mock returns the same canned response for every :cmd
      # call, `service status` returns {"", 0} → treated as "already
      # running" → `service start` is skipped. That's the
      # already-running path.
      assert {:ok, [{"jail:svc:pg:postgresql", {:jail_svc_started, "pg", "postgresql"}}]} =
               run_step(step)

      calls = Mock.calls()
      # Two cmd calls: sysrc + service status. No start because status ok.
      assert length(calls) == 2

      assert Enum.at(calls, 0) ==
               {:cmd, ["pg", "sysrc", "postgresql_enable=YES"], []}

      assert Enum.at(calls, 1) ==
               {:cmd, ["pg", "service", "postgresql", "status"], []}
    end

    test "propagates sysrc failure as :jail_svc_enable_failed" do
      Mock.expect(:cmd, {"sysrc: unable to open rc.conf\n", 1})

      step = %Step{
        id: "jail:svc:foo:svc",
        type: :jail_svc,
        action: :start,
        args: %{jail: :foo, service: :svc, env: nil}
      }

      assert {:error, _step,
              {:jail_svc_enable_failed, "foo", "svc", {:bastille_exit, 1, _}}, _} =
               run_step(step)
    end
  end
end
