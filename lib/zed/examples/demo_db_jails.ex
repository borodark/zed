defmodule Zed.Examples.DemoDbJails do
  @moduledoc """
  Two production database jails — Postgres 16 and ClickHouse — declared
  in Zed and brought up by a single `converge()` call. Replaces
  `scripts/demo-pg-bootstrap.sh` + `scripts/demo-ch-bootstrap.sh`
  (~200 lines of shell) that the S6 milestone used.

  This is the first end-to-end target after Path B: exercises every
  DSL construct (packages, jail_param, mount_in_jail, jail_file,
  setup do, service) against a real workload without opening Path C
  (jail-contained app deployment).

  ## Usage on mac-248

      cd ~/zed && git pull && mix compile
      sh scripts/smoke-db-jails.sh clean          # tear down prior state
      doas iex --sname db --cookie exmc -S mix

      iex> Zed.Examples.DemoDbJails.converge() |> IO.inspect(limit: :infinity)
      # second run — expect all no-ops
      iex> Zed.Examples.DemoDbJails.converge() |> IO.inspect(limit: :infinity)

      sh scripts/smoke-db-jails.sh verify

  ## Scope

  Database user/database creation and password setting are NOT here —
  those are per-app concerns (craftplan, plausible) that belong with
  their app declarations. This module covers only: jail up, package
  in, data volume mounted, service running, minimal config for
  bastille0 subnet access. That is enough to prove the DB jails work.
  """

  use Zed.DSL

  # ClickHouse config XML overlays live in scripts/clickhouse-config/
  # on the host. Read into module attributes at compile time so their
  # values inline as string literals wherever they're referenced —
  # a defp function call inside the DSL block would be captured as
  # AST and never evaluated. The @external_resource directives make
  # `mix compile` re-fire when the XML files change.
  @ch_config_dir Path.expand("../../../scripts/clickhouse-config", __DIR__)
  @external_resource Path.join(@ch_config_dir, "logs.xml")
  @external_resource Path.join(@ch_config_dir, "ipv4-only.xml")
  @external_resource Path.join(@ch_config_dir, "low-resources.xml")
  @external_resource Path.join(@ch_config_dir, "default-profile-low-resources-overrides.xml")

  @ch_logs File.read!(Path.join(@ch_config_dir, "logs.xml"))
  @ch_ipv4 File.read!(Path.join(@ch_config_dir, "ipv4-only.xml"))
  @ch_lowres File.read!(Path.join(@ch_config_dir, "low-resources.xml"))
  @ch_users_lowres File.read!(
                     Path.join(@ch_config_dir, "default-profile-low-resources-overrides.xml")
                   )

  deploy :demo_db, pool: "mac_zroot" do
    dataset "jails/pg" do
      compression :lz4
    end

    dataset "data/pg" do
      compression :lz4
    end

    dataset "jails/ch" do
      compression :lz4
    end

    dataset "data/ch" do
      compression :lz4
    end

    # ------------------------------------------------------------------
    # Postgres 16
    # ------------------------------------------------------------------
    jail :pg do
      dataset "jails/pg"
      hostname "pg"
      ip4 "10.17.89.20/24"
      release "15.0-RELEASE"

      packages ["postgresql16-server"]
      jail_param "allow.sysvipc", true

      # Data volume mounted at Postgres's default data root. Everything
      # under /var/db/postgres inside the jail — including initdb's
      # output at /var/db/postgres/16/data — lands on this dataset,
      # which survives jail destroy/recreate.
      dataset "data/pg", mount_in_jail: "/var/db/postgres"

      setup do
        # sysrc-set data path once; sysrc is idempotent.
        cmd "sysrc -f /etc/rc.conf.d/postgresql postgresql_data=/var/db/postgres/16/data"

        # initdb only if the target doesn't already have a PG_VERSION
        # file. `test -f` short-circuits so re-converge is a no-op.
        # Use `oneinitdb` (not `initdb`) — the `one` prefix bypasses
        # FreeBSD's rc.d framework requirement that postgresql_enable
        # be YES. Enable is set later by the jail_svc:start step;
        # during setup we just want the one-shot init, without
        # touching service-enable state.
        cmd "test -f /var/db/postgres/16/data/PG_VERSION || service postgresql oneinitdb"

        # Network access from the bastille0 subnet. The append goes
        # through `cmd` (not `file append:`) because the target file
        # lives on the nullfs-mounted data volume; the host-side
        # rootfs path is shadowed. Shell inside the jail sees the
        # mount.
        cmd "grep -qxF 'host all all 10.17.89.0/24 scram-sha-256' /var/db/postgres/16/data/pg_hba.conf || echo 'host all all 10.17.89.0/24 scram-sha-256' >> /var/db/postgres/16/data/pg_hba.conf"

        # Listen on all interfaces inside the jail so bastille0 peers
        # can reach us.
        cmd "grep -qxF \"listen_addresses = '0.0.0.0'\" /var/db/postgres/16/data/postgresql.conf || echo \"listen_addresses = '0.0.0.0'\" >> /var/db/postgres/16/data/postgresql.conf"
      end

      service :postgresql
    end

    # ------------------------------------------------------------------
    # ClickHouse
    # ------------------------------------------------------------------
    jail :ch do
      dataset "jails/ch"
      hostname "ch"
      ip4 "10.17.89.21/24"
      release "15.0-RELEASE"

      packages ["clickhouse"]
      jail_param "allow.raw_sockets", true

      dataset "data/ch", mount_in_jail: "/var/lib/clickhouse"

      # ClickHouse pkg ships config.xml.sample; the setup block
      # activates it before starting. XML overlays for Plausible-style
      # low-resource tuning are written via jail_file — they live at
      # /usr/local/etc/clickhouse-server/{config.d,users.d}/*.xml
      # inside the jail rootfs (not on the mounted data volume, so
      # host-side jail_file writes them directly).
      jail_file "/usr/local/etc/clickhouse-server/config.d/logs.xml",
        content: @ch_logs,
        mode: 0o644

      jail_file "/usr/local/etc/clickhouse-server/config.d/ipv4-only.xml",
        content: @ch_ipv4,
        mode: 0o644

      jail_file "/usr/local/etc/clickhouse-server/config.d/low-resources.xml",
        content: @ch_lowres,
        mode: 0o644

      jail_file "/usr/local/etc/clickhouse-server/users.d/default-profile-low-resources-overrides.xml",
        content: @ch_users_lowres,
        mode: 0o644

      setup do
        # Activate the base config samples the pkg ships. `test -f`
        # short-circuits so re-converge is a no-op.
        cmd "test -f /usr/local/etc/clickhouse-server/config.xml || cp /usr/local/etc/clickhouse-server/config.xml.sample /usr/local/etc/clickhouse-server/config.xml"

        cmd "test -f /usr/local/etc/clickhouse-server/users.xml || cp /usr/local/etc/clickhouse-server/users.xml.sample /usr/local/etc/clickhouse-server/users.xml"
      end

      service :clickhouse
    end

    snapshots do
      before_deploy true
      keep 5
    end
  end
end
