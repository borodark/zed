defmodule Zed.Examples.SmokeContainedRealCluster do
  @moduledoc """
  Path C4 smoke: two jails, each containing a hello_beam release,
  configured to auto-cluster via PEER_NODE. Both nodes discover each
  other over bastille0; from any node, `Node.list/0` returns the
  other.

  The two apps share a name (`:hello_beam`) but different node names
  and IPs; both point at the same release tarball built via
  `scripts/build-real-release.sh`.

  ## Usage on mac-248

      sh scripts/build-real-release.sh
      sh scripts/smoke-contained-real-cluster.sh clean

      export SMOKE_COOKIE=abc123def
      doas env SMOKE_COOKIE=abc123def mix run -e \\
        "IO.inspect(Zed.Examples.SmokeContainedRealCluster.converge(), limit: :infinity)"

      sh scripts/smoke-contained-real-cluster.sh verify
  """

  use Zed.DSL

  deploy :smoke_contained_real_cluster, pool: "mac_zroot" do
    dataset "jails/hello_beam_a" do
      compression :lz4
    end

    dataset "jails/hello_beam_b" do
      compression :lz4
    end

    # The tarball ships `bin/hello_beam`, but each contained app has a
    # DIFFERENT app_id (hello_beam_a / _b) so their mount path and
    # service name would default to `/opt/hello_beam_a` and
    # `hello_beam_a` — which doesn't match the tarball's bin/hello_beam.
    # Override mount_in_jail + service so the layout is:
    #
    #   <jail>/root/opt/hello_beam/current/bin/hello_beam
    #   rc.d command="/opt/hello_beam/current/bin/hello_beam daemon"
    #
    # And the env file lands at /var/db/zed/hello_beam.env (default is
    # app_id — override too).

    # Node A points at B as its peer
    app :hello_beam_a do
      dataset "jails/hello_beam_a"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      mount_in_jail "/opt/hello_beam"
      service :hello_beam
      env_file "/var/db/zed/hello_beam.env"

      node_name :"hello_beam@10.17.89.93"
      cookie {:env, "SMOKE_COOKIE"}

      env %{"PEER_NODE" => "hello_beam@10.17.89.94"}

      health :tcp, host: "10.17.89.93", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      health :beam_ping,
        node: :"hello_beam@10.17.89.93",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 15,
        interval: 1000
    end

    # Node B points at A as its peer
    app :hello_beam_b do
      dataset "jails/hello_beam_b"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      mount_in_jail "/opt/hello_beam"
      service :hello_beam
      env_file "/var/db/zed/hello_beam.env"

      node_name :"hello_beam@10.17.89.94"
      cookie {:env, "SMOKE_COOKIE"}

      env %{"PEER_NODE" => "hello_beam@10.17.89.93"}

      health :tcp, host: "10.17.89.94", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      health :beam_ping,
        node: :"hello_beam@10.17.89.94",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 15,
        interval: 1000
    end

    jail :hello_beam_a do
      dataset "jails/hello_beam_a"
      hostname "hello-beam-a.local"
      ip4 "10.17.89.93/24"
      release "15.0-RELEASE"
      contains :hello_beam_a
    end

    jail :hello_beam_b do
      dataset "jails/hello_beam_b"
      hostname "hello-beam-b.local"
      ip4 "10.17.89.94/24"
      release "15.0-RELEASE"
      contains :hello_beam_b
    end
  end
end
