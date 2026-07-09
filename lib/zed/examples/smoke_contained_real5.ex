defmodule Zed.Examples.SmokeContainedReal5 do
  @moduledoc """
  Path C5 smoke: five jails on 10.17.89.100..104, each running the
  same hello_beam release, all discovering each other via libcluster
  reading Zed's cluster artifact.

  Wiring:
    * Top-level `cluster :demo do members [...] end` — Zed's
      `:cluster_config :create` step writes
      `/var/db/zed/cluster/demo.config` (one node atom per line).
    * Each jail nullfs-mounts `/var/db/zed/cluster` from the host
      read-only. The runtime.exs in hello_beam reads that file and
      wires `Cluster.Strategy.Epmd` topology.
    * `Cluster.Supervisor` in the release keeps all 5 nodes
      connected; on any node, `Node.list()` returns the other 4.

  Idempotent: re-converge is a no-op (cluster_config write is
  idempotent by content match, jail_mount short-circuits when the
  target is already mounted).

  ## Usage on mac-248

      sh scripts/build-real-release.sh   # WITH libcluster now
      sh scripts/smoke-contained-real5.sh clean

      export SMOKE_COOKIE=abc123def
      doas env SMOKE_COOKIE=abc123def mix run -e \\
        "IO.inspect(Zed.Examples.SmokeContainedReal5.converge(), limit: :infinity)"

      SMOKE_COOKIE=abc123def sh scripts/smoke-contained-real5.sh verify
  """

  use Zed.DSL

  deploy :smoke_contained_real5, pool: "mac_zroot" do
    # 5 datasets
    dataset "jails/hello_beam_100" do
      compression :lz4
    end

    dataset "jails/hello_beam_101" do
      compression :lz4
    end

    dataset "jails/hello_beam_102" do
      compression :lz4
    end

    dataset "jails/hello_beam_103" do
      compression :lz4
    end

    dataset "jails/hello_beam_104" do
      compression :lz4
    end

    # 5 apps — same release, same mount, same service; only node_name
    # and app_id differ so Zed can key steps per-app.
    app :hello_beam_100 do
      dataset "jails/hello_beam_100"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      mount_in_jail "/opt/hello_beam"
      service :hello_beam
      env_file "/var/db/zed/hello_beam.env"
      node_name :"hello_beam@10.17.89.100"
      cookie {:env, "SMOKE_COOKIE"}
      health :tcp, host: "10.17.89.100", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      health :beam_ping,
        node: :"hello_beam@10.17.89.100",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 20,
        interval: 1000
    end

    app :hello_beam_101 do
      dataset "jails/hello_beam_101"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      mount_in_jail "/opt/hello_beam"
      service :hello_beam
      env_file "/var/db/zed/hello_beam.env"
      node_name :"hello_beam@10.17.89.101"
      cookie {:env, "SMOKE_COOKIE"}
      health :tcp, host: "10.17.89.101", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      health :beam_ping,
        node: :"hello_beam@10.17.89.101",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 20,
        interval: 1000
    end

    app :hello_beam_102 do
      dataset "jails/hello_beam_102"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      mount_in_jail "/opt/hello_beam"
      service :hello_beam
      env_file "/var/db/zed/hello_beam.env"
      node_name :"hello_beam@10.17.89.102"
      cookie {:env, "SMOKE_COOKIE"}
      health :tcp, host: "10.17.89.102", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      health :beam_ping,
        node: :"hello_beam@10.17.89.102",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 20,
        interval: 1000
    end

    app :hello_beam_103 do
      dataset "jails/hello_beam_103"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      mount_in_jail "/opt/hello_beam"
      service :hello_beam
      env_file "/var/db/zed/hello_beam.env"
      node_name :"hello_beam@10.17.89.103"
      cookie {:env, "SMOKE_COOKIE"}
      health :tcp, host: "10.17.89.103", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      health :beam_ping,
        node: :"hello_beam@10.17.89.103",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 20,
        interval: 1000
    end

    app :hello_beam_104 do
      dataset "jails/hello_beam_104"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      mount_in_jail "/opt/hello_beam"
      service :hello_beam
      env_file "/var/db/zed/hello_beam.env"
      node_name :"hello_beam@10.17.89.104"
      cookie {:env, "SMOKE_COOKIE"}
      health :tcp, host: "10.17.89.104", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      health :beam_ping,
        node: :"hello_beam@10.17.89.104",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 20,
        interval: 1000
    end

    # 5 jails — each nullfs-mounts /var/db/zed/cluster from host so
    # libcluster inside sees the artifact Zed writes.
    jail :hello_beam_100 do
      dataset "jails/hello_beam_100"
      hostname "hello-beam-100.local"
      ip4 "10.17.89.100/24"
      release "15.0-RELEASE"
      contains :hello_beam_100
      nullfs_mount "/var/db/zed/cluster", into: "/var/db/zed/cluster", mode: :ro
    end

    jail :hello_beam_101 do
      dataset "jails/hello_beam_101"
      hostname "hello-beam-101.local"
      ip4 "10.17.89.101/24"
      release "15.0-RELEASE"
      contains :hello_beam_101
      nullfs_mount "/var/db/zed/cluster", into: "/var/db/zed/cluster", mode: :ro
    end

    jail :hello_beam_102 do
      dataset "jails/hello_beam_102"
      hostname "hello-beam-102.local"
      ip4 "10.17.89.102/24"
      release "15.0-RELEASE"
      contains :hello_beam_102
      nullfs_mount "/var/db/zed/cluster", into: "/var/db/zed/cluster", mode: :ro
    end

    jail :hello_beam_103 do
      dataset "jails/hello_beam_103"
      hostname "hello-beam-103.local"
      ip4 "10.17.89.103/24"
      release "15.0-RELEASE"
      contains :hello_beam_103
      nullfs_mount "/var/db/zed/cluster", into: "/var/db/zed/cluster", mode: :ro
    end

    jail :hello_beam_104 do
      dataset "jails/hello_beam_104"
      hostname "hello-beam-104.local"
      ip4 "10.17.89.104/24"
      release "15.0-RELEASE"
      contains :hello_beam_104
      nullfs_mount "/var/db/zed/cluster", into: "/var/db/zed/cluster", mode: :ro
    end

    cluster :demo do
      cookie {:env, "SMOKE_COOKIE"}

      members [
        :"hello_beam@10.17.89.100",
        :"hello_beam@10.17.89.101",
        :"hello_beam@10.17.89.102",
        :"hello_beam@10.17.89.103",
        :"hello_beam@10.17.89.104"
      ]
    end
  end
end
