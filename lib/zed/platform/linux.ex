defmodule Zed.Platform.Linux do
  @moduledoc """
  Linux platform backend (development/testing only).

  Zed targets FreeBSD and illumos for production. This backend
  exists so that the DSL, IR, convergence engine, and ZFS
  operations can be developed and tested on Linux workstations
  that have ZFS installed (e.g., Ubuntu with zfs-dkms).
  """

  @behaviour Zed.Platform

  @impl true
  def service_start(name) do
    case System.cmd("systemctl", ["start", name], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_stop(name) do
    case System.cmd("systemctl", ["stop", name], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_restart(name) do
    case System.cmd("systemctl", ["restart", name], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_status(name) do
    case System.cmd("systemctl", ["is-active", name], stderr_to_stdout: true) do
      {"active\n", 0} -> :running
      {_, _} -> :stopped
    end
  end

  @impl true
  def service_enable(name) do
    case System.cmd("systemctl", ["enable", name], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_install(name, _config) do
    {:error, "Linux service_install not implemented — use FreeBSD or illumos for production. Service: #{name}"}
  end
end
