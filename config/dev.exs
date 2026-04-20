import Config

config :zed, ZedWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4040],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  watchers: []

config :logger, level: :debug
