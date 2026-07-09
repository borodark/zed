defmodule Zed.Examples.SmokeContainedApp do
  @moduledoc """
  Path C1 smoke: a single jail with an inline app declared via
  `contains`. The app's release tarball is staged by
  `scripts/build-smoke-app-tarball.sh` before converge; the DSL points
  at the resulting fixed path.

  Exercises the Path C1 executor clauses that don't exist under Path B:
    * `:jail_app :deploy` — release tarball extracts into
      `<jails_dir>/<jail>/root/opt/hello/releases/<version>/` and
      `current` symlinks to it.
    * `:jail_service :install` — rc(8) script written into
      `<jails_dir>/<jail>/root/usr/local/etc/rc.d/hello`, mode 0755.

  Reuses Path B's `:jail_svc :start` to enable + start via bastille
  cmd sysrc + service start.

  Not proven by this smoke: whether the started daemon actually stays
  up (requires a real mix-release binary — deferred to C2/C3 with
  the DemoOffCompose cluster). Path C1 proves the plumbing; C2/C3
  prove the payload.

  ## Usage on mac-248

      sh scripts/build-smoke-app-tarball.sh
      sh scripts/smoke-contained-app.sh clean
      doas iex --sname cap --cookie exmc -S mix

      iex> Zed.Examples.SmokeContainedApp.converge() |> IO.inspect(limit: :infinity)
      # second run
      iex> Zed.Examples.SmokeContainedApp.converge() |> IO.inspect(limit: :infinity)

      sh scripts/smoke-contained-app.sh verify
  """

  use Zed.DSL

  deploy :smoke_contained_app, pool: "mac_zroot" do
    dataset "jails/hello_jail" do
      compression :lz4
    end

    app :hello do
      dataset "jails/hello_jail"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello-0.1.0.tar.gz"
      node_name :"hello@10.17.89.92"
      cookie {:env, "RELEASE_COOKIE"}
    end

    jail :hello_jail do
      dataset "jails/hello_jail"
      hostname "hello-jail.local"
      ip4 "10.17.89.92/24"
      release "15.0-RELEASE"
      contains :hello
    end
  end
end
