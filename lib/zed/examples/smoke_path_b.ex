defmodule Zed.Examples.SmokePathB do
  @moduledoc """
  Smoke test for Path B executor slices (jail_pkg, jail_mount, jail_svc,
  jail_param, depends_on). Designed to be run on mac-248 against the
  S6 bastille topology (bastille0 subnet 10.17.89.0/24, ZFS pool
  mac_zroot).

  Exercises every jail sub-step that used to be a `{:ok, :pending}`
  stub, plus jail_param passthrough and depends_on topological order.

  ## Layout

      jail :smoke_up
        packages ["curl"]            # exercises :jail_pkg :install
        jail_param "allow.sysvipc"   # exercises FreeBSD jail.conf passthrough
        nullfs_mount "/tmp"          # exercises :jail_mount :create
        service :cron                # exercises :jail_svc :start

      jail :smoke_down
        depends_on :smoke_up         # exercises topological plan sort

  ## Usage on mac-248

      # From ~/zed on mac-248 (as zedops or root with doas):
      mix compile
      iex --sname smoke --cookie exmc -S mix
      iex> Zed.Examples.SmokePathB.diff()
      iex> Zed.Examples.SmokePathB.converge()
      # Second run — should be all no-op / already-present:
      iex> Zed.Examples.SmokePathB.converge()

  See `scripts/smoke-path-b.sh` for verify + cleanup helpers.
  """

  use Zed.DSL

  deploy :smoke_pathb, pool: "mac_zroot" do
    dataset "jails/smoke_up" do
      compression :lz4
    end

    dataset "jails/smoke_down" do
      compression :lz4
    end

    jail :smoke_up do
      dataset "jails/smoke_up"
      hostname "smoke-up.local"
      ip4 "10.17.89.90/24"
      release "15.0-RELEASE"

      packages ["curl"]
      jail_param "allow.sysvipc", true
      nullfs_mount "/tmp", into: "/host_tmp", mode: :ro
      jail_file "/etc/motd", content: "hello from zed\n", mode: 0o644

      setup do
        cmd "touch /var/log/zed-setup-ran"
        file "/etc/rc.conf.d/zed_marker",
          append: "zed_setup_marker=path-b-slice-6"
      end

      service :cron
    end

    jail :smoke_down do
      dataset "jails/smoke_down"
      hostname "smoke-down.local"
      ip4 "10.17.89.91/24"
      release "15.0-RELEASE"
      depends_on :smoke_up
    end
  end
end
