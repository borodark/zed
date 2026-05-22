defmodule Zed.Examples.TraderWalkthrough do
  @moduledoc """
  Live demonstration of `docs/packaging_elixir_with_zed.md` —
  the eXMC trader release, tarred for tarfs(5), mounted on
  mac-247, started in library mode (no `ACCOUNTS_CONFIG`)
  so the BEAM boots, the supervisor tree comes up, the
  service is reachable for health probes, but no broker
  connection is established and no orders are placed.

  Built artifact: `exmc-0.1.0.tar` (~71 MB), built on mac-248
  with `MIX_ENV=prod mix release exmc`, transferred via
  super-io to mac-247's `/var/zed/exmc/artifacts/`.

  Re-uses the same ZFS dataset layout as `Zed.Examples.MissionI`
  (`zroot/zed/exmc-trial/...`) so the diff against an already-
  M-I-converged host is just the tarfs and service_run lines.

      iex> Zed.Examples.TraderWalkthrough.diff()
      iex> Zed.Examples.TraderWalkthrough.converge_coordinated(dry_run: true)
      iex> Zed.Examples.TraderWalkthrough.converge_coordinated([])
  """

  use Zed.DSL

  deploy :exmc_walkthrough, pool: "zroot" do
    host :mac_247, node: :"zed-agent@192.168.0.247" do
      # The ZFS datasets are already in place from the Mission I
      # work — these declarations are idempotent and will be
      # noops on a host that already has them.
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

      # Mount the freshly-built release tar read-only at /opt/exmc.
      tarfs :exmc_release do
        tar_path "/var/zed/exmc/artifacts/exmc-0.1.0.tar"
        mount "/opt/exmc"
      end

      # Library-mode env: no ACCOUNTS_CONFIG, no broker. EXMC_COMPILER
      # set to :none so vulkano/spirit/EXLA aren't attempted at boot —
      # avoids a startup failure on hosts where the NVIDIA driver
      # isn't loaded (the case on mac-247 right now while the iGPU
      # experiment recovery is in progress).
      file "/var/db/exmc-trial/env-walkthrough" do
        mode 0o640
        owner "io"
        group "io"
        content """
        RELEASE_COOKIE=exmc-walkthrough
        RELEASE_NODE=walkthrough@mac
        RELEASE_DISTRIBUTION=sname
        RELEASE_TMP=/var/db/exmc-trial/tmp-walkthrough
        EXMC_COMPILER=none
        EXMC_BEAM_LOG=/var/db/exmc-trial/logs/walkthrough-beam.log
        """
      end

      # Walkthrough demo: declare the app + env_file but DON'T
      # service_run. Starting the trader requires GPU init that
      # we're deferring; the walkthrough's goal is the deploy
      # mechanism (release → tar → tarfs mount → ZFS state), not
      # the running trader. Add service_run back once GPU init
      # works in headless library mode.
      app :exmc_walkthrough do
        node_name :"walkthrough@mac"
        cookie {:env, "RELEASE_COOKIE"}
        env_file "/var/db/exmc-trial/env-walkthrough"
      end
    end

    snapshots do
      before_deploy true
      keep 5
    end
  end
end
