defmodule ZedWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :zed

  @session_options [
    store: :cookie,
    key: "_zed_session",
    signing_salt: "zed-session-salt",
    same_site: "Lax",
    secure: false,
    http_only: true,
    # 8h rolling — session cookie expires when browser closes, but the
    # plug-signed content carries an inner max-age.
    max_age: 60 * 60 * 8
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], check_origin: false]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ZedWeb.Router

  @doc "Session options — exposed so the router layer can reuse them."
  def session_options, do: @session_options
end
