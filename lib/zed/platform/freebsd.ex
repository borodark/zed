defmodule Zed.Platform.FreeBSD do
  @moduledoc """
  FreeBSD platform backend.

  Service management via rc.d/sysrc. Isolation via jails.
  Packages via pkg. Boot environments via bectl.
  """

  @behaviour Zed.Platform

  @jail_conf_dir "/etc/jail.conf.d"

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

  # --- Jail Operations ---

  @doc "Install jail configuration to /etc/jail.conf.d/<name>.conf"
  def jail_install(name, config) do
    conf = generate_jail_conf(name, config)
    path = Path.join(@jail_conf_dir, "#{name}.conf")

    with :ok <- File.mkdir_p(@jail_conf_dir),
         :ok <- File.write(path, conf) do
      :ok
    end
  end

  @doc "Create and start a jail."
  def jail_create(name, _config) do
    case System.cmd("jail", ["-c", "-f", jail_conf_path(name), name], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:jail_create_failed, code, out}}
    end
  end

  @doc "Stop a running jail."
  def jail_stop(name) do
    case System.cmd("jail", ["-r", name], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, out}
    end
  end

  @doc "Remove jail configuration file."
  def jail_remove(name) do
    path = jail_conf_path(name)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Check if jail is running. Returns :running, :stopped, or {:error, reason}."
  def jail_status(name) do
    case System.cmd("jls", ["-j", name, "-q", "jid"], stderr_to_stdout: true) do
      {_, 0} -> :running
      {_, _} -> :stopped
    end
  end

  @doc "List running jails."
  def jail_list do
    case System.cmd("jls", ["-q", "name"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)

      {_, _} ->
        []
    end
  end

  defp jail_conf_path(name), do: Path.join(@jail_conf_dir, "#{name}.conf")

  @doc "Generate jail.conf content for a jail."
  def generate_jail_conf(name, config) do
    path = config[:path] || config[:mountpoint] || "/jails/#{name}"
    hostname = config[:hostname] || "#{name}.local"
    ip4 = config[:ip4]
    ip6 = config[:ip6]
    vnet = config[:vnet] || false

    # Build parameters
    params =
      [
        {"path", path},
        {"host.hostname", hostname},
        {"mount.devfs", nil},
        {"exec.clean", nil},
        {"exec.start", "/bin/sh /etc/rc"},
        {"exec.stop", "/bin/sh /etc/rc.shutdown"}
      ]
      |> maybe_add_ip4(ip4, vnet)
      |> maybe_add_ip6(ip6, vnet)
      |> maybe_add_vnet(vnet)
      |> format_jail_params()

    """
    #{name} {
    #{params}
    }
    """
  end

  defp maybe_add_ip4(params, nil, _vnet), do: params
  defp maybe_add_ip4(params, _ip4, true), do: params
  defp maybe_add_ip4(params, ip4, false), do: params ++ [{"ip4.addr", ip4}]

  defp maybe_add_ip6(params, nil, _vnet), do: params
  defp maybe_add_ip6(params, _ip6, true), do: params
  defp maybe_add_ip6(params, ip6, false), do: params ++ [{"ip6.addr", ip6}]

  defp maybe_add_vnet(params, false), do: params
  defp maybe_add_vnet(params, true), do: params ++ [{"vnet", nil}]

  defp format_jail_params(params) do
    params
    |> Enum.map(fn
      {key, nil} -> "    #{key};"
      {key, val} -> "    #{key} = \"#{val}\";"
    end)
    |> Enum.join("\n")
  end
end
