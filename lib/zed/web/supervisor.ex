defmodule Zed.Web.Supervisor do
  @moduledoc """
  Supervision tree for the `:web` role (zedweb release).

  Owns the network-facing surface: the Phoenix endpoint, the OTT ETS
  table, and — once A5a.2 lands — the OpsClient that talks to the
  zedops process over a Unix socket. Holds zero privileged capabilities.

  In `:full` (dev/test) role this supervisor is **not** started by
  `Zed.Application`; the existing `zed serve` CLI keeps doing the
  endpoint dance manually so the 175-test suite stays intact. Once
  the privilege boundary is the default everywhere, `zed serve` can be
  retired in favour of starting the release with `ZED_ROLE=web`.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      ZedWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
