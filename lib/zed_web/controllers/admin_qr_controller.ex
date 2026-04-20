defmodule ZedWeb.AdminQRController do
  @moduledoc """
  Redemption endpoint for QR-delivered one-time tokens.

  The mobile companion app scans a `zed_admin` QR, extracts the OTT,
  and POSTs it here. On success we set the admin session and return a
  redirect target; subsequent browser-side navigation hits the normal
  `/admin` LV with a valid session cookie.

  All error cases return 401 with a stable `error` string so the
  companion app can distinguish (`token_expired`, `token_used`,
  `invalid_token`).

  Rate-limited 10 requests / 60 seconds per IP via `ZedWeb.Plugs.RateLimit`.
  """

  use ZedWeb, :controller

  plug ZedWeb.Plugs.RateLimit, max: 10, window: 60, key: :ip

  def redeem(conn, %{"ott" => ott}) when is_binary(ott) do
    case Zed.Admin.OTT.consume(ott) do
      {:ok, meta} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:admin_user, Atom.to_string(meta.user))
        |> put_session(:admin_logged_in_at, :os.system_time(:second))
        |> put_session(:admin_login_method, :qr)
        |> put_status(:ok)
        |> json(%{ok: true, redirect: "/admin"})

      {:error, :not_found} ->
        send_error(conn, "invalid_token")

      {:error, :used} ->
        send_error(conn, "token_used")

      {:error, :expired} ->
        send_error(conn, "token_expired")
    end
  end

  def redeem(conn, _params) do
    send_error(conn, "ott_required")
  end

  defp send_error(conn, error_str) do
    conn
    |> put_status(:unauthorized)
    |> json(%{ok: false, error: error_str})
  end
end
