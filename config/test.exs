import Config

config :zed, ZedWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test-secret-key-base-placeholder-", 3),
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
