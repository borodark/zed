import Config

# Phoenix endpoint defaults. Runtime values (port, bind, TLS cert paths,
# secret_key_base) are set in config/runtime.exs from env vars. These
# static defaults make `mix compile` and `mix test` work without
# environment setup.
config :zed, ZedWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ZedWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Zed.PubSub,
  live_view: [signing_salt: "zed-live-view-placeholder"],
  # Endpoint does not accept connections unless started from `zed serve`.
  server: false,
  secret_key_base: String.duplicate("compile-time-placeholder-not-a-real-secret-key-base-", 2)

config :phoenix, :json_library, Jason

# Logger defaults; runtime may override.
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
