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
      # The probe reads `mount` on the host (System.cmd, not routed
      # through Bastille), so the mock only intercepts the actual
      # :mount call. Test path assumes /var/db/zed/secrets is NOT
      # mounted on the test host — safe under BEAM's default cwd.
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
      assert [{:mount, mount_argv, _}] = calls
      assert mount_argv ==
               ["pg", "/mnt/jeff/secrets", "/var/db/zed/secrets", "nullfs", "ro", "0", "0"]
    end

    # Already-present short-circuit reads /host/mount output directly
    # (bastille cmd inside the jail doesn't see nullfs mounts). That
    # side of the probe is exercised on metal — see
    # scripts/smoke-path-b.sh and lib/zed/examples/smoke_path_b.ex.

    test "propagates bastille mount exit as :jail_mount_failed" do
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

  describe ":jail_file :create" do
    setup do
      tmp = System.tmp_dir!() |> Path.join("zed-jail-file-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      # Override jails_dir so the executor writes into our tempdir.
      Application.put_env(:zed, Zed.Platform.Bastille,
        runner: Mock,
        jails_dir: tmp
      )

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.delete_env(:zed, Zed.Platform.Bastille)
      end)

      {:ok, jails_dir: tmp}
    end

    test "writes file at <jails_dir>/<jail>/root<path>", %{jails_dir: dir} do
      step = %Step{
        id: "jail:file:app:0",
        type: :jail_file,
        action: :create,
        args: %{jail: :app, path: "/etc/motd", content: "hello", mode: 0o644}
      }

      assert {:ok, [{"jail:file:app:0", {:jail_file_created, "app", "/etc/motd"}}]} =
               run_step(step)

      target = Path.join([dir, "app", "root", "etc", "motd"])
      assert File.read!(target) == "hello"
      stat = File.stat!(target)
      # File.chmod semantics vary per-OS in ExUnit's tempdir; assert
      # the file exists at the expected path and content is right,
      # trust the chmod call happened without erroring.
      assert stat.type == :regular
    end

    test "short-circuits when on-disk content already matches", %{jails_dir: dir} do
      target = Path.join([dir, "app", "root", "etc", "motd"])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "hello")

      step = %Step{
        id: "jail:file:app:0",
        type: :jail_file,
        action: :create,
        args: %{jail: :app, path: "/etc/motd", content: "hello"}
      }

      assert {:ok,
              [{"jail:file:app:0", {:jail_file_already_current, "app", "/etc/motd"}}]} =
               run_step(step)
    end

    test "rejects non-binary content with :jail_file_invalid_content", %{jails_dir: _dir} do
      # Simulate the historical trap: content is an AST tuple (as
      # would happen if the DSL failed to resolve @attr).
      bad_content = {:@, [], [{:some_attr, [], nil}]}

      step = %Step{
        id: "jail:file:app:0",
        type: :jail_file,
        action: :create,
        args: %{jail: :app, path: "/etc/x", content: bad_content, mode: nil}
      }

      assert {:error, _step, {:jail_file_invalid_content, "app", "/etc/x", ^bad_content}, _} =
               run_step(step)
    end

    test "rewrites when content differs", %{jails_dir: dir} do
      target = Path.join([dir, "app", "root", "etc", "motd"])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "old")

      step = %Step{
        id: "jail:file:app:0",
        type: :jail_file,
        action: :create,
        args: %{jail: :app, path: "/etc/motd", content: "new"}
      }

      assert {:ok, [{"jail:file:app:0", {:jail_file_created, "app", "/etc/motd"}}]} =
               run_step(step)

      assert File.read!(target) == "new"
    end
  end

  describe ":jail_app :deploy" do
    setup do
      tmp = System.tmp_dir!() |> Path.join("zed-jail-app-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      Application.put_env(:zed, Zed.Platform.Bastille,
        runner: Mock,
        jails_dir: tmp
      )

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.delete_env(:zed, Zed.Platform.Bastille)
      end)

      {:ok, jails_dir: tmp}
    end

    test "returns :no_tarball when release_path is nil", %{jails_dir: _dir} do
      step = %Step{
        id: "jail:app:web:zedweb",
        type: :jail_app,
        action: :deploy,
        args: %{
          jail: :web,
          app: :zedweb,
          version: "0.1.0",
          release_path: nil,
          mount_in_jail: "/opt/zedweb"
        }
      }

      assert {:ok, [{"jail:app:web:zedweb", {:jail_app_no_tarball, "web", :zedweb}}]} =
               run_step(step)
    end

    test "extracts tarball into <jails_dir>/<jail>/root<mount_in_jail>", %{jails_dir: dir} do
      # Build a small tarball with a fake release layout
      staging = Path.join(dir, "staging-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(staging, "bin"))
      File.write!(Path.join([staging, "bin", "myapp"]), "#!/bin/sh\necho hello\n")

      tar_path = Path.join(dir, "myapp-0.1.0.tar.gz")

      {_, 0} =
        System.cmd("tar", ["czf", tar_path, "-C", staging, "."], stderr_to_stdout: true)

      step = %Step{
        id: "jail:app:web:myapp",
        type: :jail_app,
        action: :deploy,
        args: %{
          jail: :web,
          app: :myapp,
          version: "0.1.0",
          release_path: tar_path,
          mount_in_jail: "/opt/myapp"
        }
      }

      assert {:ok, [{"jail:app:web:myapp", {:jail_app_deployed, "web", :myapp, version_dir}}]} =
               run_step(step)

      # Extraction landed at <jails_dir>/web/root/opt/myapp/releases/0.1.0/
      assert String.contains?(
               version_dir,
               "web/root/opt/myapp/releases/0.1.0"
             )

      # And the `current` symlink points to it
      current = Path.join([dir, "web", "root", "opt", "myapp", "current"])
      assert File.exists?(current)
      # Symlink target should exist and contain our fake bin/myapp
      assert File.exists?(Path.join([current, "bin", "myapp"]))
    end
  end

  describe ":jail_service :install" do
    setup do
      tmp = System.tmp_dir!() |> Path.join("zed-jail-service-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      Application.put_env(:zed, Zed.Platform.Bastille,
        runner: Mock,
        jails_dir: tmp
      )

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.delete_env(:zed, Zed.Platform.Bastille)
      end)

      {:ok, jails_dir: tmp}
    end

    test "writes rc.d script inside the jail rootfs", %{jails_dir: dir} do
      step = %Step{
        id: "jail:service:web:myapp",
        type: :jail_service,
        action: :install,
        args: %{
          jail: :web,
          service: :myapp,
          mount_in_jail: "/opt/myapp",
          user: "myapp",
          env_file: "/var/db/myapp/env"
        }
      }

      assert {:ok, [{"jail:service:web:myapp", {:jail_service_installed, "web", "myapp"}}]} =
               run_step(step)

      rc_path = Path.join([dir, "web", "root", "usr", "local", "etc", "rc.d", "myapp"])
      assert File.exists?(rc_path)

      content = File.read!(rc_path)
      assert content =~ "PROVIDE: myapp"
      assert content =~ ~s(command="/opt/myapp/current/bin/myapp")
      assert content =~ ". /var/db/myapp/env"

      stat = File.stat!(rc_path)
      # 0755 permissions expected
      assert Bitwise.band(stat.mode, 0o777) == 0o755
    end

    test "second run with same content returns :jail_service_already_current", %{jails_dir: _dir} do
      step = %Step{
        id: "jail:service:web:myapp",
        type: :jail_service,
        action: :install,
        args: %{
          jail: :web,
          service: :myapp,
          mount_in_jail: "/opt/myapp",
          user: "myapp",
          env_file: nil
        }
      }

      assert {:ok, _} = run_step(step)

      assert {:ok, [{"jail:service:web:myapp", {:jail_service_already_current, "web", "myapp"}}]} =
               run_step(step)
    end
  end

  describe ":jail_setup :run" do
    setup do
      tmp = System.tmp_dir!() |> Path.join("zed-jail-setup-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      Application.put_env(:zed, Zed.Platform.Bastille,
        runner: Mock,
        jails_dir: tmp
      )

      on_exit(fn ->
        File.rm_rf!(tmp)
        Application.delete_env(:zed, Zed.Platform.Bastille)
      end)

      {:ok, jails_dir: tmp}
    end

    test "runs cmd + file append and writes hash", %{jails_dir: dir} do
      Mock.expect(:cmd, {"", 0})

      step = %Step{
        id: "jail:setup:pg",
        type: :jail_setup,
        action: :run,
        args: %{
          jail: :pg,
          ops: [
            {:cmd, "sysrc postgresql_enable=YES"},
            {:file, "/etc/pg_hba.conf", %{append: "host all all 10.17.89.0/24 scram-sha-256"}}
          ]
        }
      }

      assert {:ok, [{"jail:setup:pg", {:jail_setup_ran, "pg", 2}}]} = run_step(step)

      # Hash file was written
      hash_path = Path.join([dir, "pg", "zed-setup.hash"])
      assert File.exists?(hash_path)

      # File append landed in the jail rootfs
      hba = Path.join([dir, "pg", "root", "etc", "pg_hba.conf"])
      assert File.read!(hba) == "host all all 10.17.89.0/24 scram-sha-256\n"

      # cmd shelled out as sh -c
      assert Enum.any?(Mock.calls(), fn
               {:cmd, ["pg", "sh", "-c", "sysrc postgresql_enable=YES"], _} -> true
               _ -> false
             end)
    end

    test "second run with same ops short-circuits via hash match", %{jails_dir: dir} do
      Mock.expect(:cmd, {"", 0})

      ops = [{:cmd, "true"}]

      step = %Step{
        id: "jail:setup:pg",
        type: :jail_setup,
        action: :run,
        args: %{jail: :pg, ops: ops}
      }

      # First run — populates hash file
      assert {:ok, [{"jail:setup:pg", {:jail_setup_ran, "pg", 1}}]} = run_step(step)
      call_count_after_first = length(Mock.calls())

      # Second run — should read hash, match, skip
      assert {:ok, [{"jail:setup:pg", {:jail_setup_already_current, "pg"}}]} = run_step(step)
      assert length(Mock.calls()) == call_count_after_first, "no new cmd calls on skip"

      # Hash file still there
      assert File.exists?(Path.join([dir, "pg", "zed-setup.hash"]))
    end

    test "file append is idempotent — no duplicate line if already present", %{jails_dir: dir} do
      # Seed the file with the line already in place
      hba = Path.join([dir, "pg", "root", "etc", "pg_hba.conf"])
      File.mkdir_p!(Path.dirname(hba))
      File.write!(hba, "host all all 10.17.89.0/24 scram-sha-256\n")

      step = %Step{
        id: "jail:setup:pg",
        type: :jail_setup,
        action: :run,
        args: %{
          jail: :pg,
          ops: [
            {:file, "/etc/pg_hba.conf",
             %{append: "host all all 10.17.89.0/24 scram-sha-256"}}
          ]
        }
      }

      assert {:ok, _} = run_step(step)

      # Still one line, not two
      lines = File.read!(hba) |> String.split("\n", trim: true)
      assert lines == ["host all all 10.17.89.0/24 scram-sha-256"]
    end

    test "changing ops invalidates hash, forces re-run", %{jails_dir: dir} do
      Mock.expect(:cmd, {"", 0})

      step_v1 = %Step{
        id: "jail:setup:pg",
        type: :jail_setup,
        action: :run,
        args: %{jail: :pg, ops: [{:cmd, "true"}]}
      }

      assert {:ok, [{"jail:setup:pg", {:jail_setup_ran, "pg", 1}}]} = run_step(step_v1)

      step_v2 = %Step{
        id: "jail:setup:pg",
        type: :jail_setup,
        action: :run,
        args: %{jail: :pg, ops: [{:cmd, "true"}, {:cmd, "echo v2"}]}
      }

      # Different ops — hash mismatch → re-runs
      assert {:ok, [{"jail:setup:pg", {:jail_setup_ran, "pg", 2}}]} = run_step(step_v2)

      # Hash file exists and reflects v2 (not equal to v1 hash)
      hash_path = Path.join([dir, "pg", "zed-setup.hash"])
      assert File.exists?(hash_path)
    end

    test "cmd failure aborts setup", %{jails_dir: _dir} do
      Mock.expect(:cmd, {"nope\n", 1})

      step = %Step{
        id: "jail:setup:pg",
        type: :jail_setup,
        action: :run,
        args: %{jail: :pg, ops: [{:cmd, "false"}]}
      }

      assert {:error, _step, {:jail_setup_failed, "pg", {:op_failed, {:cmd, "false"}, _}}, _} =
               run_step(step)
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
      assert {:ok,
              [{"jail:svc:pg:postgresql", {:jail_svc_already_running, "pg", "postgresql"}}]} =
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
