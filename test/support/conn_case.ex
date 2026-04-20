defmodule ZedWeb.ConnCase do
  @moduledoc """
  Test case for HTTP + LiveView end-to-end tests against ZedWeb.Endpoint.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ZedWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      @endpoint ZedWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
