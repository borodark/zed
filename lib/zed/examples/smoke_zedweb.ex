defmodule Zed.Examples.SmokeZedweb do
  @moduledoc """
  Path C7 smoke: Zed's own `zedweb` release deployed by Zed itself
  into a single jail. First real-app migration proof — everything
  before it was `hello_beam`, a hand-rolled 6 MB throwaway.

  Distinct from every prior Path C smoke because zedweb:
    * Has a real HTTP endpoint (Bandit on port 4040).
    * Requires `ZED_SECRET_KEY_BASE` at boot (config/runtime.exs, C7
      adds the `:zed_web_secret_key_base` Catalog slot).
    * Uses `env %{...}` on the `app` block — new C7 wiring that
      resolves `{:secret, ...}` refs in extra_env against the same
      encrypted secrets dataset the cookie already uses.

  Single jail on 10.17.89.30/24 (avoids DemoOffCompose's .10 and
  SmokeContainedRealSecrets' .95/.96). No libcluster this round —
  the smoke proves the release boots and serves HTTP; multi-node
  zedweb + zedops is a downstream slice.

  Prereqs on mac-248:

      # Once. Adds the zed_web_secret_key_base slot if not already
      # present. Idempotent — existing slots skip by fingerprint.
      BOOTSTRAP_PASSPHRASE=smoke-c7-pass sh scripts/bootstrap-secrets.sh

      # Every time zedweb source changes.
      sh scripts/build-zedweb-release.sh

      sh scripts/smoke-zedweb.sh clean
      doas mix run -e "IO.inspect(Zed.Examples.SmokeZedweb.converge(), limit: :infinity)"
      sh scripts/smoke-zedweb.sh verify
  """

  use Zed.DSL

  deploy :smoke_zedweb, pool: "mac_zroot" do
    dataset "jails/smoke_zedweb" do
      compression :lz4
    end

    app :zedweb do
      dataset "jails/smoke_zedweb"
      version "0.1.0"
      release_path "/var/tmp/zed-smoke/zedweb-0.1.0.tar.gz"
      mount_in_jail "/opt/zedweb"
      service :zedweb
      env_file "/var/db/zed/zedweb.env"
      node_name :"zedweb@10.17.89.30"
      cookie {:secret, :demo_cluster_cookie}

      # Path C7 — resolved at converge against the encrypted secrets
      # dataset (mac_zroot/zed). ZED_SERVE=1 flips runtime.exs to
      # supervise the endpoint; ZED_SECRET_KEY_BASE is the Phoenix
      # signing key; ZED_WEB_BIND lets Bandit answer from the jail's
      # bastille0 address instead of loopback.
      env %{
        "ZED_SERVE" => "1",
        "ZED_WEB_PORT" => "4040",
        "ZED_WEB_BIND" => "10.17.89.30",
        "ZED_WEB_HOST" => "10.17.89.30",
        "ZED_SECRET_KEY_BASE" => {:secret, :zed_web_secret_key_base}
      }

      health :tcp, host: "10.17.89.30", port: 4040, timeout: 3000, attempts: 20, interval: 1000

      health :http,
        url: "http://10.17.89.30:4040/health",
        expect: 200,
        timeout: 5000,
        attempts: 20,
        interval: 1000
    end

    jail :smoke_zedweb do
      dataset "jails/smoke_zedweb"
      hostname "smoke-zedweb.local"
      ip4 "10.17.89.30/24"
      release "15.0-RELEASE"
      contains :zedweb
    end
  end
end
