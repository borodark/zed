defmodule Zed.Application do
  @moduledoc """
  OTP application entry point for the `:zed` app.

  Boot sequence:

    1. `Zed.Role.assert_release_role!/0` (A5a.7) — refuse to start
       if the release name promised the privilege boundary but the
       resolved role would silently bypass it.
    2. Resolve role via `Zed.Role.current/0`.
    3. Start always-on children (`Phoenix.PubSub`, `Zed.Admin.OTT`)
       under every role; they're cheap and keep the test suite's
       LiveView assertions happy without ever-on endpoint cost.
    4. Start the role-specific supervisor branch:
         - `:web`  → `Zed.Web.Supervisor` (Phoenix + OpsClient pool)
         - `:ops`  → `Zed.Ops.Supervisor` (socket listener)
         - `:full` → no extra branch; `zed serve` drives endpoint

  See `Zed.Role` for the full role model and the boot-time guard.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # A5a.7: refuse to boot if the release name promised the privilege
    # boundary but ZED_ROLE was forgotten. Hard-fail here is preferable
    # to a silent fallback to :full mode.
    :ok = Zed.Role.assert_release_role!()

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
