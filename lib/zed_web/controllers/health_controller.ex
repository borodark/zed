defmodule ZedWeb.HealthController do
  @moduledoc """
  Liveness probe. Answers 200 as soon as the endpoint accepts
  requests — used by Zed's own `health :http` step (Path C7's
  SmokeZedweb) and by external monitors.

  Intentionally does not depend on session, cookies, base state, or
  any subsystem beyond the endpoint itself. Health checks that
  cascade dependencies belong in a separate `/health/deep` route.
  """

  use ZedWeb, :controller

  def check(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok\n")
  end
end
