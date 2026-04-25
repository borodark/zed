defmodule Zed.Role do
  @moduledoc """
  Process-role dispatch for the A5a privilege boundary.

  A single `:zed` OTP application is built from one repo, but is shipped
  as two `mix release` targets — `zedweb` (network-facing, no privilege)
  and `zedops` (capability-scoped escalation via doas). The role is
  resolved at boot time from `ZED_ROLE`, falls back to
  `Application.get_env(:zed, :role)`, and finally defaults to `:full`
  for development and `mix test`.

  Roles
  -----

    * `:web`  — start the Phoenix endpoint, OTT ledger, OpsClient.
                No bastille / zfs / pf shellouts permitted.

    * `:ops`  — start the Unix-socket listener + audit log writer.
                No HTTP listener permitted. Holds the doas rules.

    * `:full` — single-process dev/test mode. Starts the always-on bits
                (PubSub, OTT) and leaves endpoint startup to
                `zed serve`. Preserves the pre-A5a behaviour exactly so
                the existing 175-test suite keeps working.

  The boundary is a process boundary, not a code boundary — every module
  is loaded in every release. Role only governs which supervisor branch
  starts at boot.
  """

  @type t :: :web | :ops | :full

  @valid [:web, :ops, :full]

  @spec current() :: t
  def current do
    case System.get_env("ZED_ROLE") do
      nil -> Application.get_env(:zed, :role, :full)
      env -> parse(env)
    end
    |> validate()
  end

  defp parse("web"), do: :web
  defp parse("ops"), do: :ops
  defp parse("full"), do: :full
  defp parse(other), do: raise(ArgumentError, "ZED_ROLE=#{inspect(other)} not in #{inspect(@valid)}")

  defp validate(role) when role in @valid, do: role
  defp validate(other), do: raise(ArgumentError, ":zed :role = #{inspect(other)} not in #{inspect(@valid)}")
end
