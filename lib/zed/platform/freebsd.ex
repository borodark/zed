defmodule Zed.Platform.FreeBSD do
  @moduledoc """
  FreeBSD platform backend.

  Service management via rc.d/sysrc. Isolation via jails.
  Packages via pkg. Boot environments via bectl.
  """

  @behaviour Zed.Platform

  alias Zed.Platform.Bastille

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

  @doc """
  Install a jail via `bastille create`.

  Idempotent: skips creation when `Bastille.exists?/1` reports the
  name is already registered. If `config[:jail_params]` is a non-empty
  list, appends those params to the bastille-generated jail.conf
  block (`/usr/local/bastille/jails/<name>/jail.conf`). Params take
  effect on the next jail start.

  `config[:release]` overrides the Bastille adapter's `default_release`.
  """
  def jail_install(name, config) do
    ip4 = config[:ip4]
    release = config[:release]
    params = config[:jail_params] || []

    with :ok <- ensure_bastille_jail(name, ip4, release),
         {:ok, params_changed} <- apply_jail_params_overlay(name, params),
         :ok <- restart_if_params_changed(name, params_changed) do
      :ok
    end
  end

  # FreeBSD jail params only take effect on jail start. Bastille.create
  # auto-starts the jail with the stock jail.conf — before our overlay
  # runs. If the overlay wrote new params, stop the jail now; the
  # jail_create step running next will restart it fresh with the new
  # params applied. No-op if the overlay wrote nothing (idempotent
  # re-converge) or the jail is already stopped.
  defp restart_if_params_changed(_name, false), do: :ok

  defp restart_if_params_changed(name, true) do
    case jail_status(name) do
      :running ->
        case Bastille.stop(name) do
          :ok -> :ok
          {:error, reason} -> {:error, {:jail_install_stop_failed, reason}}
        end

      :stopped ->
        :ok
    end
  end

  @doc """
  Start a jail via `bastille start`.

  Idempotent: probes the kernel via `jls` — no-op if the jail is
  already running.
  """
  def jail_create(name, _config) do
    case jail_status(name) do
      :running ->
        :ok

      :stopped ->
        case Bastille.start(name) do
          :ok -> :ok
          {:error, reason} -> {:error, {:jail_create_failed, reason}}
        end
    end
  end

  @doc "Stop a running jail via bastille."
  def jail_stop(name) do
    case Bastille.stop(name) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Destroy a jail via bastille (removes rootfs + registration)."
  def jail_remove(name) do
    case Bastille.exists?(name) do
      true ->
        case Bastille.destroy(name) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      false ->
        :ok
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

  # Create the jail via bastille if it doesn't exist. Bastille itself
  # handles the rootfs + jail.conf + registration. IP is required.
  # Release falls back to Bastille adapter's default.
  defp ensure_bastille_jail(_name, nil, _release),
    do: {:error, {:jail_install_failed, :missing_ip4}}

  defp ensure_bastille_jail(name, ip4, release) do
    if Bastille.exists?(name) do
      :ok
    else
      opts = [ip: ip4] |> maybe_add_release(release)

      case Bastille.create(name, opts) do
        :ok -> :ok
        {:error, reason} -> {:error, {:jail_install_failed, reason}}
      end
    end
  end

  defp maybe_add_release(opts, nil), do: opts
  defp maybe_add_release(opts, release), do: [{:release, release} | opts]

  # Append jail.conf params to bastille's per-jail file if they're not
  # already present. Grep-before-append keeps this idempotent across
  # re-converge. Params take effect on next jail start — the caller
  # (jail_install) uses the returned `changed?` boolean to decide
  # whether a restart is needed.
  defp apply_jail_params_overlay(_name, []), do: {:ok, false}

  defp apply_jail_params_overlay(name, params) do
    conf_path = bastille_jail_conf(name)

    case File.read(conf_path) do
      {:ok, contents} ->
        new_lines =
          params
          |> Enum.reject(fn {k, _v} -> String.contains?(contents, "#{k} =") end)
          |> Enum.map(fn {k, v} -> "    #{k} = #{render_overlay_value(v)};" end)

        case new_lines do
          [] ->
            {:ok, false}

          _ ->
            with {:ok, patched} <- inject_before_closing_brace(contents, new_lines),
                 :ok <- File.write(conf_path, patched) do
              {:ok, true}
            else
              {:error, reason} -> {:error, {:jail_params_overlay_failed, reason}}
            end
        end

      {:error, reason} ->
        {:error, {:jail_params_overlay_failed, reason}}
    end
  end

  defp bastille_jail_conf(name),
    do: Path.join([Bastille.jails_dir(), name, "jail.conf"])

  defp render_overlay_value(true), do: "true"
  defp render_overlay_value(false), do: "false"
  defp render_overlay_value(v) when is_integer(v), do: Integer.to_string(v)
  defp render_overlay_value(v) when is_binary(v), do: "\"#{v}\""

  # Insert new lines just before the last `}` in the file. Bastille's
  # jail.conf has one block per file, so this is unambiguous.
  defp inject_before_closing_brace(contents, new_lines) do
    case String.split(contents, ~r/\}\s*\z/, parts: 2, include_captures: true) do
      [head, close, tail] ->
        {:ok, head <> Enum.join(new_lines, "\n") <> "\n" <> close <> tail}

      _ ->
        {:error, :closing_brace_not_found}
    end
  end

  @doc "Generate jail.conf content for a jail."
  def generate_jail_conf(name, config) do
    path = config[:path] || config[:mountpoint] || "/jails/#{name}"
    hostname = config[:hostname] || "#{name}.local"
    ip4 = config[:ip4]
    ip6 = config[:ip6]
    vnet = config[:vnet] || false
    extra_params = config[:jail_params] || []

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
      |> append_extra_params(extra_params)
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

  defp append_extra_params(params, extras) do
    Enum.reduce(extras, params, fn {key, value}, acc ->
      acc ++ [{key, render_param_value(value)}]
    end)
  end

  # jail.conf values: booleans render as "true"/"false" without quotes;
  # ints render bare; strings quoted by format_jail_params/1.
  defp render_param_value(true), do: {:bare, "true"}
  defp render_param_value(false), do: {:bare, "false"}
  defp render_param_value(v) when is_integer(v), do: {:bare, Integer.to_string(v)}
  defp render_param_value(v) when is_binary(v), do: v

  defp format_jail_params(params) do
    params
    |> Enum.map(fn
      {key, nil} -> "    #{key};"
      {key, {:bare, val}} -> "    #{key} = #{val};"
      {key, val} -> "    #{key} = \"#{val}\";"
    end)
    |> Enum.join("\n")
  end
end
