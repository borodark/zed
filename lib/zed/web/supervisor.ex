defmodule Zed.Web.Supervisor do
  @moduledoc """
  Supervision tree for the `:web` role (zedweb release).

  Owns the network-facing surface: the Phoenix endpoint and the
  `OpsClient.Pool` of persistent Unix-socket connections to the
  zedops process. Holds zero privileged capabilities — every
  bastille / zfs / pf operation flows through the pool.

  Configuration is read from `Application.get_env(:zed,
  Zed.Web.OpsClient, [])`:

      config :zed, Zed.Web.OpsClient,
        path: "/var/run/zed/ops.sock",
        size: 4

  In `:full` (dev/test) role this supervisor is **not** started by
  `Zed.Application`; the existing `zed serve` CLI keeps doing the
  endpoint dance manually so the 175-test suite stays intact.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    pool_opts = Application.get_env(:zed, Zed.Web.OpsClient, [])

    children = [
      {Zed.Web.OpsClient.Pool, pool_opts},
      ZedWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
