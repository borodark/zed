defmodule ZedWeb.AdminController do
  use ZedWeb, :controller

  alias Zed.Secrets.Verify

  def root(conn, _params) do
    case get_session(conn, :admin_user) do
      nil -> redirect(conn, to: "/admin/login")
      _ -> redirect(conn, to: "/admin")
    end
  end

  def new_session(conn, _params) do
    render(conn, :new_session,
      error: conn.assigns[:login_error],
      csrf_token: get_csrf_token()
    )
  end

  def create_session(conn, %{"password" => password}) do
    base = Application.get_env(:zed, :base)

    if base && verify_admin(base, password) do
      conn
      |> configure_session(renew: true)
      |> put_session(:admin_user, "admin")
      |> put_session(:admin_logged_in_at, :os.system_time(:second))
      |> redirect(to: "/admin")
    else
      # Constant-time path: always verify something even on miss to
      # avoid timing-leak of "user exists". Here the only user is
      # :admin, so the leak is trivial, but match the pattern.
      _ = Verify.password(password, "$pbkdf2-sha256$i=600000$aaaa$bbbb")

      conn
      |> assign(:login_error, "Invalid password.")
      |> new_session(%{})
    end
  end

  def create_session(conn, _params) do
    conn
    |> assign(:login_error, "Password required.")
    |> new_session(%{})
  end

  def delete_session(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/admin/login")
  end

  defp verify_admin(base, password) do
    props = Zed.ZFS.Property.get_all("#{base}/zed")

    with path when is_binary(path) <- Map.get(props, "secret.admin_passwd.path"),
         {:ok, stored_hash} <- File.read(path) do
      Verify.password(password, String.trim(stored_hash))
    else
      _ -> false
    end
  end
end
