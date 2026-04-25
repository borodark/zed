defmodule Zed.Role do
  @moduledoc """
  Process-role dispatch for the A5a privilege boundary.

  A single `:zed` OTP application is built from one repo and shipped
  as two `mix release` targets — `zedweb` (network-facing, no
  privilege) and `zedops` (capability-scoped escalation via doas).
  The role governs which supervisor branch boots; everything else
  (modules, config, app spec) is identical across releases.

  Resolution at boot time
  -----------------------

    1. `ZED_ROLE` env var, if set, wins.
    2. Otherwise `RELEASE_NAME` implies the role: `zedweb`→`:web`,
       `zedops`→`:ops`. Wired in `config/runtime.exs` so operators
       never have to remember to set `ZED_ROLE` for a release.
    3. Otherwise `Application.get_env(:zed, :role)`.
    4. Otherwise default `:full` (dev / `mix test` / `iex -S mix`).

  Roles
  -----

    * `:web`  — start `Zed.Web.Supervisor` (Phoenix endpoint +
                `Zed.Web.OpsClient.Pool`). No bastille / zfs / pf
                shellouts; everything mutating goes over the Unix
                socket to zedops.

    * `:ops`  — start `Zed.Ops.Supervisor` (Unix-socket listener +
                bastille handler). No HTTP listener. Holds the doas
                rules from `docs/doas.conf.zedops`.

    * `:full` — single-process dev/test mode. Starts the always-on
                bits (PubSub, OTT) and leaves endpoint startup to
                `zed serve`. Preserves pre-A5a behaviour exactly so
                the existing test suite runs unchanged.

  Boot-time guard (A5a.7)
  -----------------------

  `assert_release_role!/0` runs first thing in `Zed.Application.start/2`
  and refuses to boot when the release name promised the boundary
  but the resolved role is `:full` (e.g. operator set
  `ZED_ROLE=full` inside a `zedweb` release). The supervisor crash
  takes the BEAM down before any socket binds — fail-closed beats
  fail-open for a privilege check.

  The boundary is a process boundary, not a code boundary; role only
  governs which supervisor branch starts at boot.
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

  @doc """
  Boot-time guard (A5a.7): a release named after a privileged role
  must not silently fall back to `:full`.

  Releases `zedweb` and `zedops` promise the privilege boundary. If
  the release is built but `ZED_ROLE` and `:zed, :role` are both
  unset, `current/0` returns `:full` and the boundary is bypassed —
  potentially without anyone noticing. This guard hard-fails at
  boot when:

      release name ∈ {zedweb, zedops}  AND  current() == :full

  Returns `:ok` for the safe cases (any non-release run, any role
  explicitly set to match the release name, role `:full` under a
  release that does not promise the boundary). Raises otherwise —
  the supervisor crash takes the BEAM down before any socket binds
  or any HTTP listener accepts.
  """
  @spec assert_release_role!() :: :ok
  def assert_release_role! do
    case {release_name(), current()} do
      {"zedweb", role} when role != :web -> raise_release_mismatch("zedweb", :web, role)
      {"zedops", role} when role != :ops -> raise_release_mismatch("zedops", :ops, role)
      _ -> :ok
    end
  end

  # Returns the release name as a binary, or `nil` when not running
  # under `mix release`. RELEASE_NAME is exported by mix-generated
  # release start scripts; absent under `mix run` / `mix test` /
  # `iex -S mix` and under escript boots.
  defp release_name, do: System.get_env("RELEASE_NAME")

  defp raise_release_mismatch(release, expected, actual) do
    raise """
    refusing to boot: release "#{release}" promises ZED_ROLE=#{expected} \
    but the role at boot is #{inspect(actual)}.

    Set ZED_ROLE=#{expected} in the release's env (rel/env.sh.eex or \
    config/runtime.exs), or boot under a different release name.
    """
  end

  defp parse("web"), do: :web
  defp parse("ops"), do: :ops
  defp parse("full"), do: :full
  defp parse(other), do: raise(ArgumentError, "ZED_ROLE=#{inspect(other)} not in #{inspect(@valid)}")

  defp validate(role) when role in @valid, do: role
  defp validate(other), do: raise(ArgumentError, ":zed :role = #{inspect(other)} not in #{inspect(@valid)}")
end
