defmodule Zed.JailTest do
  use ExUnit.Case, async: true

  alias Zed.Converge.{Diff, Plan}
  alias Zed.IR.Node
  alias Zed.Platform.FreeBSD

  describe "jail.conf generation" do
    test "generates basic jail.conf with ip4" do
      conf = FreeBSD.generate_jail_conf("web", %{
        path: "/jails/web",
        ip4: "10.0.1.10/24"
      })

      assert conf =~ "web {"
      assert conf =~ ~s(path = "/jails/web";)
      assert conf =~ ~s(host.hostname = "web.local";)
      assert conf =~ ~s(ip4.addr = "10.0.1.10/24";)
      assert conf =~ "mount.devfs;"
      assert conf =~ ~s(exec.start = "/bin/sh /etc/rc";)
      assert conf =~ ~s(exec.stop = "/bin/sh /etc/rc.shutdown";)
    end

    test "generates vnet jail without ip4.addr" do
      conf = FreeBSD.generate_jail_conf("api", %{
        path: "/jails/api",
        hostname: "api.prod.local",
        vnet: true,
        ip4: "10.0.1.20"
      })

      assert conf =~ "api {"
      assert conf =~ ~s(host.hostname = "api.prod.local";)
      assert conf =~ "vnet;"
      refute conf =~ "ip4.addr"
    end

    test "generates jail with ip6" do
      conf = FreeBSD.generate_jail_conf("dual", %{
        path: "/jails/dual",
        ip4: "10.0.1.30",
        ip6: "fd00::30"
      })

      assert conf =~ ~s(ip4.addr = "10.0.1.30";)
      assert conf =~ ~s(ip6.addr = "fd00::30";)
    end

    test "uses default hostname if not specified" do
      conf = FreeBSD.generate_jail_conf("myapp", %{path: "/jails/myapp"})

      assert conf =~ ~s(host.hostname = "myapp.local";)
    end
  end

  describe "jail plan generation" do
    test "jail create produces install + create steps" do
      diff = [
        %Diff{
          resource: %Node{
            id: :web_jail,
            type: :jail,
            config: %{
              dataset: "jails/web",
              ip4: "10.0.1.10/24",
              contains: :web
            }
          },
          action: :create,
          current: %{jail: nil},
          desired: %{dataset: "jails/web", ip4: "10.0.1.10/24"},
          changes: [{:jail, nil, "web_jail"}]
        }
      ]

      plan = Plan.from_diff(diff, pool: "jeff")

      assert length(plan.steps) == 2

      [install_step, create_step] = plan.steps

      assert install_step.type == :jail
      assert install_step.action == :install
      assert install_step.args.jail == :web_jail
      assert install_step.args.ip4 == "10.0.1.10/24"

      assert create_step.type == :jail
      assert create_step.action == :create
      assert create_step.args.jail == :web_jail
      assert create_step.args.contains == :web
      assert create_step.deps == ["jail:install:web_jail"]
    end

    test "jail steps depend on dataset" do
      diff = [
        %Diff{
          resource: %Node{
            id: :api_jail,
            type: :jail,
            config: %{dataset: "jails/api"}
          },
          action: :create,
          changes: [{:jail, nil, "api_jail"}]
        }
      ]

      plan = Plan.from_diff(diff, pool: "tank")

      [install_step | _] = plan.steps
      assert install_step.deps == ["dataset:create:jails/api"]
    end

    test "jail with packages produces pkg step" do
      diff = [
        %Diff{
          resource: %Node{
            id: :pg,
            type: :jail,
            config: %{
              dataset: "jails/pg",
              ip4: "10.17.89.20/24",
              packages: ["postgresql16-server"]
            }
          },
          action: :create,
          changes: [{:jail, nil, "pg"}]
        }
      ]

      plan = Plan.from_diff(diff, pool: "tank")

      pkg_step = Enum.find(plan.steps, &(&1.type == :jail_pkg))
      assert pkg_step != nil
      assert pkg_step.action == :install
      assert pkg_step.args.packages == ["postgresql16-server"]
      assert pkg_step.deps == ["jail:create:pg"]
    end

    test "jail with services produces svc steps" do
      diff = [
        %Diff{
          resource: %Node{
            id: :pg,
            type: :jail,
            config: %{
              dataset: "jails/pg",
              ip4: "10.17.89.20/24",
              services: [{:postgresql, %{env: %{"PGDATA" => "/var/db/postgres"}}}]
            }
          },
          action: :create,
          changes: [{:jail, nil, "pg"}]
        }
      ]

      plan = Plan.from_diff(diff, pool: "tank")

      svc_step = Enum.find(plan.steps, &(&1.type == :jail_svc))
      assert svc_step != nil
      assert svc_step.action == :start
      assert svc_step.args.service == :postgresql
    end

    test "jail with mounts produces mount steps" do
      diff = [
        %Diff{
          resource: %Node{
            id: :zedweb,
            type: :jail,
            config: %{
              dataset: "jails/zedweb",
              ip4: "10.17.89.10/24",
              mounts: [{"/var/run/zed", %{into: "/host_run_zed", mode: :ro}}]
            }
          },
          action: :create,
          changes: [{:jail, nil, "zedweb"}]
        }
      ]

      plan = Plan.from_diff(diff, pool: "tank")

      mount_step = Enum.find(plan.steps, &(&1.type == :jail_mount))
      assert mount_step != nil
      assert mount_step.action == :create
      assert mount_step.args.host_path == "/var/run/zed"
      assert mount_step.args.jail_path == "/host_run_zed"
      assert mount_step.args.mode == :ro
    end

    test "jail sub-steps sorted: jail < jail_pkg < jail_mount < jail_svc" do
      diff = [
        %Diff{
          resource: %Node{
            id: :pg,
            type: :jail,
            config: %{
              dataset: "jails/pg",
              ip4: "10.17.89.20/24",
              packages: ["postgresql16-server"],
              services: [{:postgresql, %{}}],
              mounts: [{"/data", %{into: "/mnt/data"}}]
            }
          },
          action: :create,
          changes: [{:jail, nil, "pg"}]
        }
      ]

      plan = Plan.from_diff(diff, pool: "tank")
      types = Enum.map(plan.steps, & &1.type)

      jail_idx = Enum.find_index(types, &(&1 == :jail))
      pkg_idx = Enum.find_index(types, &(&1 == :jail_pkg))
      mount_idx = Enum.find_index(types, &(&1 == :jail_mount))
      svc_idx = Enum.find_index(types, &(&1 == :jail_svc))

      assert jail_idx < pkg_idx, "jail before jail_pkg"
      assert pkg_idx < mount_idx, "jail_pkg before jail_mount"
      assert mount_idx < svc_idx, "jail_mount before jail_svc"
    end

    test "jail steps sorted after datasets, before apps" do
      diff = [
        %Diff{
          resource: %Node{id: :myapp, type: :app, config: %{version: "1.0.0", dataset: "apps/myapp"}},
          action: :create,
          changes: [{:version, nil, "1.0.0"}]
        },
        %Diff{
          resource: %Node{id: :myjail, type: :jail, config: %{dataset: "jails/myjail"}},
          action: :create,
          changes: [{:jail, nil, "myjail"}]
        },
        %Diff{
          resource: %Node{id: "jails/myjail", type: :dataset, config: %{}},
          action: :create,
          changes: [{:exists, false, true}]
        }
      ]

      plan = Plan.from_diff(diff, pool: "jeff")

      types = plan.steps |> Enum.map(& &1.type)

      # Find indices
      dataset_idx = Enum.find_index(types, &(&1 == :dataset))
      jail_idx = Enum.find_index(types, &(&1 == :jail))
      app_idx = Enum.find_index(types, &(&1 == :app))

      assert dataset_idx < jail_idx, "dataset should come before jail"
      assert jail_idx < app_idx, "jail should come before app"
    end
  end
end
