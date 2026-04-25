defmodule Zed.Examples.DemoOffCompose do
  @moduledoc """
  Demo deployment: five BEAM apps + two database jails, all replacing
  what is currently shipped as `docker-compose` stacks. See
  [specs/demo-cluster-plan.md](../../specs/demo-cluster-plan.md) for
  the framing and the order of operations.

  This module is the **MVP shape** — uses only primitives the DSL
  already supports (`dataset`, `app`, `jail`, `cluster`, `snapshots`).
  The richer verbs (`packages`, `service`, `nullfs_mount`, `pf_rdr`,
  `app` block inside `jail`) are listed in the demo plan and land in
  follow-on iterations. Today this module proves that:

    1. The IR validator accepts the seven-jail topology.
    2. Every secret reference resolves against the (extended)
       `Zed.Secrets.Catalog`.
    3. `MyInfra.Demo.diff/0` returns a planned change set rather than
       crashing.

  It does NOT yet drive a real converge against bastille — that
  needs the IR-to-bastille mapping for the new fields, which is the
  next iteration.

  Usage:

      iex> Zed.Examples.DemoOffCompose.diff()
      iex> Zed.Examples.DemoOffCompose.converge(dry_run: true)
  """

  use Zed.DSL

  deploy :demo, pool: "zroot_mac" do
    # ----------------------------------------------------------------
    # Datasets — one per jail root, plus one per stateful jail's data
    # volume. Replaces docker-compose's named volumes.
    # ----------------------------------------------------------------

    dataset "jails/pg" do
      compression :lz4
    end

    dataset "data/pg" do
      compression :lz4
      mountpoint "/var/db/postgres"
    end

    dataset "jails/ch" do
      compression :lz4
    end

    dataset "data/ch" do
      compression :lz4
      mountpoint "/var/lib/clickhouse"
    end

    dataset "jails/zedweb" do
      compression :lz4
    end

    dataset "jails/craftplan" do
      compression :lz4
    end

    dataset "jails/plausible" do
      compression :lz4
    end

    dataset "jails/livebook" do
      compression :lz4
    end

    dataset "jails/exmc" do
      compression :lz4
    end

    dataset "data/exmc" do
      compression :lz4
      mountpoint "/var/db/exmc"
    end

    # ----------------------------------------------------------------
    # BEAM apps — five releases, all sharing one cookie so they form
    # one distributed Erlang cluster over bastille0. Each app's
    # `dataset` points at the jail root that hosts its release.
    # ----------------------------------------------------------------

    app :zedweb do
      dataset "jails/zedweb"
      version "0.1.0"
      node_name :"zedweb@10.17.89.10"
      cookie {:secret, :demo_cluster_cookie, :value}
    end

    app :craftplan do
      dataset "jails/craftplan"
      version "0.1.0"
      node_name :"craftplan@10.17.89.11"
      cookie {:secret, :demo_cluster_cookie, :value}
    end

    app :plausible do
      dataset "jails/plausible"
      version "0.1.0"
      node_name :"plausible@10.17.89.12"
      cookie {:secret, :demo_cluster_cookie, :value}
    end

    app :livebook do
      dataset "jails/livebook"
      version "0.1.0"
      node_name :"livebook@10.17.89.13"
      cookie {:secret, :demo_cluster_cookie, :value}
    end

    app :exmc do
      dataset "jails/exmc"
      version "0.1.0"
      node_name :"exmc@10.17.89.14"
      cookie {:secret, :demo_cluster_cookie, :value}
    end

    # ----------------------------------------------------------------
    # Jails — seven total. Five wrap the BEAM apps; two are
    # database-only (postgres, clickhouse) and have no `contains`.
    # ----------------------------------------------------------------

    jail :zedweb_jail do
      dataset "jails/zedweb"
      hostname "zedweb"
      ip4 "10.17.89.10/24"
      contains :zedweb
    end

    jail :craftplan_jail do
      dataset "jails/craftplan"
      hostname "craftplan"
      ip4 "10.17.89.11/24"
      contains :craftplan
    end

    jail :plausible_jail do
      dataset "jails/plausible"
      hostname "plausible"
      ip4 "10.17.89.12/24"
      contains :plausible
    end

    jail :livebook_jail do
      dataset "jails/livebook"
      hostname "livebook"
      ip4 "10.17.89.13/24"
      contains :livebook
    end

    jail :exmc_jail do
      dataset "jails/exmc"
      hostname "exmc"
      ip4 "10.17.89.14/24"
      contains :exmc
    end

    # Database jails — no `contains` because no BEAM app runs inside.
    # Postgres and ClickHouse are started by their own rc.d services
    # once the jail and data dataset are in place. The MVP DSL has no
    # `service` or `packages` verbs yet, so those steps are operator
    # follow-up; the demo plan tracks the gap.

    jail :pg_jail do
      dataset "jails/pg"
      hostname "pg"
      ip4 "10.17.89.20/24"
    end

    jail :ch_jail do
      dataset "jails/ch"
      hostname "ch"
      ip4 "10.17.89.21/24"
    end

    # ----------------------------------------------------------------
    # Cluster — distributed Erlang over bastille0. Shared cookie;
    # libcluster :static_topology with the five BEAM nodes.
    # ----------------------------------------------------------------

    cluster :demo do
      cookie {:secret, :demo_cluster_cookie, :value}

      members [
        :"zedweb@10.17.89.10",
        :"craftplan@10.17.89.11",
        :"plausible@10.17.89.12",
        :"livebook@10.17.89.13",
        :"exmc@10.17.89.14"
      ]
    end

    # ----------------------------------------------------------------
    # Snapshots — pre-deploy snapshot every time, retain ten generations
    # for emergency rollback.
    # ----------------------------------------------------------------

    snapshots do
      before_deploy true
      keep 10
    end
  end
end
