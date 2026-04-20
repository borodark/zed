defmodule ZedWeb do
  @moduledoc """
  Entry point for ZedWeb — the Phoenix LiveView admin UI.

  Use `use ZedWeb, :controller`, `use ZedWeb, :live_view`, etc. from
  web modules to pick up the right imports and base modules.

  The endpoint is NOT supervised by `Zed.Application`. Use
  `zed serve --base <dataset>` to start it. Other CLI verbs
  (bootstrap init, status, verify, ...) run without a web process.
  """

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: ZedWeb.Layouts]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {ZedWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.Component

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ZedWeb.Endpoint,
        router: ZedWeb.Router,
        statics: ZedWeb.static_paths()
    end
  end

  @doc """
  Dispatch to the appropriate block based on the `which` tag.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
