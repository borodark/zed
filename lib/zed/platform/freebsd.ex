defmodule Zed.Platform.FreeBSD do
  @moduledoc """
  FreeBSD platform backend.

  Service management via rc.d/sysrc. Isolation via jails.
  Packages via pkg. Boot environments via bectl.
  """

  @behaviour Zed.Platform

  @impl true
  def service_start(name) do
    case System.cmd("service", [name, "start"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_stop(name) do
    case System.cmd("service", [name, "stop"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_restart(name) do
    case System.cmd("service", [name, "restart"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_status(name) do
    case System.cmd("service", [name, "status"], stderr_to_stdout: true) do
      {_, 0} -> :running
      {_, _} -> :stopped
    end
  end

  @impl true
  def service_enable(name) do
    case System.cmd("sysrc", ["#{name}_enable=YES"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @impl true
  def service_install(name, config) do
    script = generate_rc_script(name, config)
    path = "/usr/local/etc/rc.d/#{name}"

    with :ok <- File.write(path, script),
         :ok <- File.chmod(path, 0o755) do
      service_enable(name)
    end
  end

  defp generate_rc_script(name, config) do
    user = config[:user] || name
    command = config[:command] || "/opt/#{name}/current/bin/#{name}"
    pidfile = config[:pidfile] || "/var/run/#{name}.pid"
    env_file = config[:env_file]

    env_line = if env_file, do: "\nload_rc_config_env #{name} #{env_file}", else: ""

    """
    #!/bin/sh

    # PROVIDE: #{name}
    # REQUIRE: LOGIN DAEMON NETWORKING
    # KEYWORD: shutdown

    . /etc/rc.subr

    name="#{name}"
    rcvar="#{name}_enable"

    #{name}_user="#{user}"
    pidfile="#{pidfile}"
    command="#{command}"
    command_args="daemon"#{env_line}

    load_rc_config $name
    run_rc_command "$1"
    """
  end
end
