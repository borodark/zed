import Config

# Runtime configuration — applied when `zed serve` starts the endpoint.
# CLI verbs that don't need the endpoint (bootstrap init, status, ...)
# never hit this path because they don't set ZED_SERVE=1.

if System.get_env("ZED_SERVE") == "1" do
  secret_key_base =
    System.get_env("ZED_SECRET_KEY_BASE") ||
      raise """
      ZED_SECRET_KEY_BASE is not set. Generate one with:
          elixir -e 'IO.puts(:crypto.strong_rand_bytes(64) |> Base.encode64())'
      """

  port = String.to_integer(System.get_env("ZED_WEB_PORT") || "4040")
  bind = System.get_env("ZED_WEB_BIND") || "127.0.0.1"

  bind_ip =
    case bind |> String.split(".") |> Enum.map(&Integer.parse/1) do
      [{a, ""}, {b, ""}, {c, ""}, {d, ""}] -> {a, b, c, d}
      _ -> {127, 0, 0, 1}
    end

  tls_cert = System.get_env("ZED_TLS_CERT")
  tls_key = System.get_env("ZED_TLS_KEY")

  endpoint_opts =
    [
      secret_key_base: secret_key_base,
      server: true,
      url: [host: System.get_env("ZED_WEB_HOST") || "localhost", port: port]
    ]

  endpoint_opts =
    if tls_cert && tls_key && File.exists?(tls_cert) && File.exists?(tls_key) do
      Keyword.put(endpoint_opts, :https,
        ip: bind_ip,
        port: port,
        certfile: tls_cert,
        keyfile: tls_key,
        otp_app: :zed
      )
    else
      Keyword.put(endpoint_opts, :http, ip: bind_ip, port: port)
    end

  config :zed, ZedWeb.Endpoint, endpoint_opts
end
