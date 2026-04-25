defmodule Zed.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    role = Zed.Role.current()

    children = always_on_children() ++ role_children(role)

    opts = [strategy: :one_for_one, name: Zed.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Phoenix.PubSub is started in every role: LiveView assertions in tests
  # depend on it, and OTT broadcasts go through it whenever the web role
  # is up. The OTT ledger is GenServer + ETS; idle cost is negligible
  # and keeping it always-on means tests share one process with `serve`.
  defp always_on_children do
    [
      {Phoenix.PubSub, name: Zed.PubSub},
      Zed.Admin.OTT
    ]
  end

  defp role_children(:full), do: []
  defp role_children(:web), do: [Zed.Web.Supervisor]
  defp role_children(:ops), do: [Zed.Ops.Supervisor]
end
