defmodule ZedWeb.Router do
  use ZedWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ZedWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_admin do
    plug ZedWeb.Plugs.RequireAdmin
  end

  scope "/", ZedWeb do
    pipe_through :browser

    get "/", AdminController, :root
    get "/admin/login", AdminController, :new_session
    post "/admin/login", AdminController, :create_session
    post "/admin/logout", AdminController, :delete_session
  end

  scope "/admin", ZedWeb do
    pipe_through [:browser, :require_admin]

    live_session :admin,
      on_mount: [{ZedWeb.Plugs.RequireAdmin, :ensure_admin}] do
      live "/", AdminLive.Dashboard, :index
    end
  end
end
