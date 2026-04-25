defmodule Zed.Examples.DemoOffCompose do
  @moduledoc """
  Demo deployment: five BEAM apps + two database jails, all replacing
  what is currently shipped as `docker-compose` stacks. See
  [specs/demo-cluster-plan.md](../../specs/demo-cluster-plan.md) for
  the framing and the order of operations.

  This module uses the **enriched jail DSL** (S3): inline `app` blocks
  inside `jail`, `packages`, `service`, `nullfs_mount`, and
  `depends_on`. The inline `app` desugars at compile time into a
  top-level app + `contains` on the jail.

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
    end

    dataset "jails/ch" do
      compression :lz4
    end

    dataset "data/ch" do
      compression :lz4
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
    end

    # ----------------------------------------------------------------
    # Database jails — no BEAM app, just packages + services.
    # Replaces docker-compose's `plausible_db` and `plausible_events_db`.
    # ----------------------------------------------------------------

    jail :pg do
      dataset "jails/pg"
      hostname "pg"
      ip4 "10.17.89.20/24"
      release "15.0-RELEASE"
      packages ["postgresql16-server"]
      dataset "data/pg", mount_in_jail: "/var/db/postgres"
      service :postgresql, env: %{"PGDATA" => "/var/db/postgres/16/data"}
    end

    jail :ch do
      dataset "jails/ch"
      hostname "ch"
      ip4 "10.17.89.21/24"
      release "15.0-RELEASE"
      packages ["clickhouse"]
      dataset "data/ch", mount_in_jail: "/var/lib/clickhouse"
      service :clickhouse
    end

    # ----------------------------------------------------------------
    # BEAM jails — each contains an inline app that desugars into a
    # top-level app + `contains` reference. Shared cookie for the
    # distributed Erlang cluster over bastille0.
    # ----------------------------------------------------------------

    jail :zedweb do
      dataset "jails/zedweb"
      hostname "zedweb"
      ip4 "10.17.89.10/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]

      app :zedweb do
        version "0.1.0"
        node_name :"zedweb@10.17.89.10"
        cookie {:secret, :demo_cluster_cookie, :value}
        health :http, url: "http://10.17.89.10:4040/health", expect: 200
      end

      nullfs_mount "/var/run/zed", into: "/host_run_zed", mode: :ro
    end

    jail :craftplan do
      dataset "jails/craftplan"
      hostname "craftplan"
      ip4 "10.17.89.11/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]
      depends_on :pg

      app :craftplan do
        version "0.1.0"
        node_name :"craftplan@10.17.89.11"
        cookie {:secret, :demo_cluster_cookie, :value}
        health :http, url: "http://10.17.89.11:4000/health", expect: 200
      end
    end

    jail :plausible do
      dataset "jails/plausible"
      hostname "plausible"
      ip4 "10.17.89.12/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]
      depends_on [:pg, :ch]

      app :plausible do
        version "0.1.0"
        node_name :"plausible@10.17.89.12"
        cookie {:secret, :demo_cluster_cookie, :value}
        health :http, url: "http://10.17.89.12:8000/api/health", expect: 200
      end
    end

    jail :livebook do
      dataset "jails/livebook"
      hostname "livebook"
      ip4 "10.17.89.13/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]

      app :livebook do
        version "0.1.0"
        node_name :"livebook@10.17.89.13"
        cookie {:secret, :demo_cluster_cookie, :value}
        health :http, url: "http://10.17.89.13:8080/", expect: 200
      end
    end

    jail :exmc do
      dataset "jails/exmc"
      hostname "exmc"
      ip4 "10.17.89.14/24"
      release "15.0-RELEASE"
      packages ["erlang-runtime27"]

      app :exmc do
        version "0.1.0"
        node_name :"exmc@10.17.89.14"
        cookie {:secret, :demo_cluster_cookie, :value}
        health :beam_ping, timeout: 5_000
      end
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
