defmodule ZedWeb.Plugs.RequireAdmin do
  @moduledoc """
  Gate for authenticated admin routes.

  - As a `Plug`: redirects to `/admin/login` if `session[:admin_user]`
    is unset, otherwise passes the conn through.
  - As a `Phoenix.LiveView` on_mount handler with the `:ensure_admin`
    lifecycle stage: halts with `{:redirect, "/admin/login"}` when
    there is no admin session.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_session(conn, :admin_user) do
      nil ->
        conn
        |> redirect(to: "/admin/login")
        |> halt()

      _user ->
        conn
    end
  end

  @doc """
  LiveView `on_mount` entry point. Called as
  `{ZedWeb.Plugs.RequireAdmin, :ensure_admin}` in the `live_session`
  declaration.
  """
  def on_mount(:ensure_admin, _params, session, socket) do
    case Map.get(session, "admin_user") do
      nil -> {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
      _user -> {:cont, socket}
    end
  end
end
