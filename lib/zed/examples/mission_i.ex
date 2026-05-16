defmodule Zed.Examples.MissionI do
  @moduledoc """
  Mission I — exmc trader deployed to mac-247 via tarfs.

  Exercises three IR types:
    * `dataset` — the artifact + state ZFS datasets
    * `tarfs`   — the release tar mounted read-only at /opt/exmc
    * `file`    — the env file at /var/db/exmc-trial/env

  Service start (rc.d unit + `service exmc-trial start`) is deferred
  to M-I.4 — `bin/exmc daemon` is invoked manually after `converge`
  in this iteration.

  Run:

      iex> Zed.Examples.MissionI.converge_coordinated(dry_run: true)
  """

  use Zed.DSL

  deploy :exmc_trial, pool: "zroot" do
    host :mac_247, node: :"zed-agent@192.168.0.247" do
      dataset "zed" do
        mountpoint :none
      end

      dataset "zed/exmc-trial" do
        mountpoint :none
      end

      dataset "zed/exmc-trial/artifacts" do
        mountpoint "/var/zed/exmc/artifacts"
        compression :off
      end

      dataset "zed/exmc-trial/state" do
        mountpoint "/var/db/exmc-trial"
        compression :lz4
        quota "20G"
      end

      tarfs :exmc_release do
        tar_path "/var/zed/exmc/artifacts/exmc-mi1.tar"
        mount "/opt/exmc"
      end

      file "/var/db/exmc-trial/env" do
        mode 0o640
        owner "io"
        group "io"
        content """
        RELEASE_COOKIE=exmc
        RELEASE_NODE=trial@mac
        RELEASE_DISTRIBUTION=sname
        RELEASE_TMP=/var/db/exmc-trial/tmp
        EXMC_COMPILER=vulkan
        ACCOUNTS_CONFIG=/var/db/exmc-trial/accounts.config
        EXMC_BEAM_LOG=/var/db/exmc-trial/logs/beam.log
        """
      end

      # M-I.4a: declare the app + health probes so Phase 2.5 fires
      # after every coordinated converge.  The app entry is otherwise
      # informational in this iteration (deploy_release is a no-op
      # because the artifact is already on disk via the tarfs mount);
      # the :health list is what drives `Zed.Converge.Health`.
      app :exmc_trial do
        node_name :"trial@mac"
        cookie {:env, "RELEASE_COOKIE"}
        env_file "/var/db/exmc-trial/env"
        # Probes run on the controller (per F3 finding in
        # docs/dual-mac-health-smoke.md) — must target reachable
        # per-host addresses, not loopback.  beam_ping omitted because
        # the trader uses sname (trial@mac) while the controller uses
        # long names; EPMD doesn't bridge those.
        health :tcp, host: "192.168.0.247", port: 4000
      end

      # M-I.4b: declarative service start.  Idempotent — alive_check
      # short-circuits if the named node is already in epmd.
      service_run :exmc_trial do
        command "/opt/exmc/bin/exmc"
        args ["daemon"]
        cd "/var/db/exmc-trial"
        env_file "/var/db/exmc-trial/env"
        alive_check {:epmd, "trial"}
      end
    end

    snapshots do
      before_deploy true
      keep 5
    end
  end
end
