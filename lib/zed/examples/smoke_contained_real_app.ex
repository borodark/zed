defmodule Zed.Examples.SmokeContainedRealApp do
  @moduledoc """
  Path C3 smoke: a single jail containing a REAL mix release
  (`hello_beam` — see `hello_beam/` in the repo). Extends the C1/C2
  smoke pattern with:

    * Real mix release, not a shell stub (proves env-file threading,
      relative symlinks, rc.d template compatibility with mix
      release's daemon-mode entry point).
    * Cookie resolution via `{:env, "SMOKE_COOKIE"}` — operator sets
      SMOKE_COOKIE before invoking converge; Zed's :jail_app :deploy
      writes /var/db/zed/hello_beam.env inside the jail.
    * `:beam_ping` health probe from the host BEAM to the jailed
      BEAM node over bastille0 — proves distributed Erlang works.

  ## Usage on mac-248

      # Build the release once
      sh scripts/build-real-release.sh

      # Clean any prior smoke state
      sh scripts/smoke-contained-real-app.sh clean

      # Converge with a shared cookie
      export SMOKE_COOKIE=abc123
      doas -E iex --sname host --cookie abc123 -S mix

      iex> Zed.Examples.SmokeContainedRealApp.converge() |> IO.inspect(limit: :infinity)
      # then, from the same iex:
      iex> Node.ping(:"hello_beam@10.17.89.93")  # => :pong

      sh scripts/smoke-contained-real-app.sh verify
  """

  use Zed.DSL

  deploy :smoke_contained_real_app, pool: "mac_zroot" do
    dataset "jails/hello_beam_jail" do
      compression :lz4
    end

    app :hello_beam do
      dataset "jails/hello_beam_jail"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/hello_beam-0.1.0.tar.gz"
      node_name :"hello_beam@10.17.89.93"
      cookie {:env, "SMOKE_COOKIE"}

      # C2 probe first — epmd listens on 4369 once BEAM boots.
      health :tcp, host: "10.17.89.93", port: 4369, timeout: 3000, attempts: 15, interval: 1000

      # C3 probe — distributed Erlang connect. Cookie MUST match the
      # value written into the jail's env file, and the probing BEAM
      # sets its cookie to match before pinging.
      health :beam_ping,
        node: :"hello_beam@10.17.89.93",
        cookie: {:env, "SMOKE_COOKIE"},
        timeout: 5000,
        attempts: 15,
        interval: 1000
    end

    jail :hello_beam_jail do
      dataset "jails/hello_beam_jail"
      hostname "hello-beam-jail.local"
      ip4 "10.17.89.93/24"
      release "15.0-RELEASE"
      contains :hello_beam
    end
  end
end
