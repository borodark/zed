defmodule Zed.Converge.Executor do
  @moduledoc """
  Execute a convergence plan step by step.

  Handles `:dataset`, `:app`, `:service`, and `:jail` step types with
  real ZFS/platform operations. Jail sub-steps (`:jail_pkg`,
  `:jail_mount`, `:jail_svc`) shell out through
  `Zed.Platform.Bastille`.

  If any step fails, returns immediately with the failure
  so the caller can trigger rollback.
  """

  alias Zed.Converge.{Plan, Step}
  alias Zed.ZFS.{Dataset, Property}
  alias Zed.Beam.Release
  alias Zed.Platform.Bastille

  @doc "Execute a plan. Returns {:ok, results} or {:error, step, reason, partial}."
  def run(%Plan{steps: steps, dry_run: true}, _platform) do
    steps
    |> Enum.map(fn step -> {step.id, :would_execute} end)
    |> then(&{:ok, &1})
  end

  def run(%Plan{steps: steps}, platform) do
    steps
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, results} ->
      case execute_step(step, platform) do
        :ok -> {:cont, {:ok, [{step.id, :ok} | results]}}
        {:ok, detail} -> {:cont, {:ok, [{step.id, detail} | results]}}
        {:error, reason} -> {:halt, {:error, step, reason, results}}
      end
    end)
  end

  # --- Step Execution (grouped by pattern) ---

  defp execute_step(%Step{type: :dataset, action: :create, args: args}, _platform) do
    pool_path = args[:pool_path] || args.path

    case Dataset.create(pool_path, args.properties) do
      {:ok, _} ->
        Property.set(pool_path, "managed", "true")
        :ok

      {:error, msg, _code} ->
        {:error, {:dataset_create_failed, pool_path, msg}}
    end
  end

  defp execute_step(%Step{type: :dataset, action: :update, args: args}, _platform) do
    pool_path = args[:pool_path] || args.path

    case Dataset.set_property(pool_path, args.property, args.value) do
      {:ok, _} -> :ok
      {:error, msg, _} -> {:error, {:dataset_set_failed, pool_path, args.property, msg}}
    end
  end

  defp execute_step(%Step{type: :app, action: :create, args: args}, _platform) do
    pool_path = args[:pool_path] || args[:dataset]
    version = args.version |> to_string()

    with {:ok, deploy_detail} <- deploy_release(args, version),
         :ok <- stamp_app_properties(pool_path, args, version) do
      {:ok, deploy_detail}
    end
  end

  defp execute_step(%Step{type: :service, action: :install, args: args}, platform) do
    config = %{
      command: Path.join([args.mountpoint, "current", "bin", args.service]),
      user: args[:user] || args.service,
      env_file: args[:env_file]
    }

    case platform.service_install(args.service, config) do
      :ok -> :ok
      {:error, reason} -> {:error, {:service_install_failed, args.service, reason}}
    end
  end

  defp execute_step(%Step{type: :service, action: :restart, args: args}, platform) do
    case platform.service_restart(args.service) do
      :ok -> :ok
      {:error, reason} -> {:error, {:service_restart_failed, args.service, reason}}
    end
  end

  defp execute_step(%Step{type: :jail, action: :install, args: args}, platform) do
    config = %{
      path: args.path,
      hostname: args.hostname,
      ip4: args.ip4,
      ip6: args.ip6,
      vnet: args.vnet,
      release: args[:release],
      jail_params: args[:jail_params] || []
    }

    jail_name = args.jail |> to_string()

    case platform.jail_install(jail_name, config) do
      :ok -> :ok
      {:error, reason} -> {:error, {:jail_install_failed, jail_name, reason}}
    end
  end

  defp execute_step(%Step{type: :jail, action: :create, args: args}, platform) do
    jail_name = args.jail |> to_string()

    with :ok <- create_jail(jail_name, platform),
         :ok <- stamp_jail_properties(args) do
      {:ok, :jail_created}
    end
  end

  # --- Jail sub-steps ---

  # pkg install -y runs inside the jail via `bastille cmd`. pkg itself
  # is idempotent — already-installed packages are a no-op that still
  # exits 0.
  defp execute_step(%Step{type: :jail_pkg, action: :install, args: args}, _platform) do
    jail = to_string(args.jail)
    packages = Enum.map(args.packages, &to_string/1)

    case Bastille.cmd(jail, ["pkg", "install", "-y" | packages]) do
      {:ok, _output} -> {:ok, {:jail_pkg_installed, jail, packages}}
      {:error, reason} -> {:error, {:jail_pkg_failed, jail, packages, reason}}
    end
  end

  # Nullfs mount is not idempotent — probe the jail's own mount table
  # first and short-circuit if `jail_path` is already the target of a
  # mount. Otherwise call `bastille mount`.
  defp execute_step(%Step{type: :jail_mount, action: :create, args: args}, _platform) do
    jail = to_string(args.jail)
    host_path = to_string(args.host_path)
    jail_path = to_string(args.jail_path)
    mode = args[:mode] |> mode_to_string()

    case jail_mount_present?(jail, jail_path) do
      true ->
        {:ok, {:jail_mount_already_present, jail, jail_path}}

      false ->
        case Bastille.mount(jail, host_path, jail_path, mode: mode) do
          :ok -> {:ok, {:jail_mount_created, jail, host_path, jail_path}}
          {:error, reason} -> {:error, {:jail_mount_failed, jail, jail_path, reason}}
        end
    end
  end

  # sysrc <svc>_enable=YES, then service <svc> start. Both run inside
  # the jail via `bastille cmd`. sysrc is idempotent. Service start is
  # gated on a status probe so re-converge is a no-op.
  defp execute_step(%Step{type: :jail_svc, action: :start, args: args}, _platform) do
    jail = to_string(args.jail)
    service = to_string(args.service)

    with :ok <- enable_service(jail, service),
         :ok <- start_service_if_needed(jail, service) do
      {:ok, {:jail_svc_started, jail, service}}
    end
  end

  # Tarfs mount: idempotent.  If the requested mountpoint is already
  # bound to the requested tar, no-op.  Otherwise call
  # `doas mount -t tarfs <tar> <mount>`.  The kmod must be loaded
  # (host setup; persist via tarfs_load=YES in /boot/loader.conf).
  defp execute_step(%Step{type: :tarfs, action: :mount, args: args}, _platform) do
    case tarfs_mount_status(args.mount) do
      {:ok, src} when src == args.tar_path ->
        {:ok, {:tarfs_already_mounted, args.mount}}

      {:ok, other_src} ->
        {:error, {:tarfs_mount_conflict, args.mount, other_src}}

      :not_mounted ->
        case System.cmd("doas", ["mount", "-t", "tarfs", args.tar_path, args.mount],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> {:ok, {:tarfs_mounted, args.mount}}
          {out, code} -> {:error, {:tarfs_mount_failed, args.mount, String.trim(out), code}}
        end
    end
  end

  # File write: idempotent.  If on-disk content matches, no-op;
  # otherwise rewrite and apply mode if specified.  Owner/group
  # changes are out of scope for now — assume parent dataset is
  # already chown'd to the right user.
  defp execute_step(%Step{type: :file, action: :write, args: args}, _platform) do
    desired = args.content

    current =
      case File.read(args.path) do
        {:ok, c} -> c
        _ -> nil
      end

    cond do
      current == desired ->
        {:ok, {:file_already_current, args.path}}

      true ->
        path = args.path
        File.mkdir_p!(Path.dirname(path))

        case File.write(path, desired) do
          :ok ->
            if args.mode, do: File.chmod!(path, args.mode)
            {:ok, {:file_written, path}}

          {:error, reason} ->
            {:error, {:file_write_failed, path, reason}}
        end
    end
  end

  # Service run: idempotent.  alive_check (currently only :epmd) lets
  # the executor short-circuit if the service is already up.  When
  # spawning, the env file (sourced via `set -a`-style shell wrapping)
  # provides RELEASE_COOKIE / RELEASE_NODE / app-specific env vars.
  # The command itself is expected to background-fork (mix release's
  # `daemon` mode does this); the executor doesn't tail it.
  defp execute_step(%Step{type: :service_run, action: :start, args: args}, _platform) do
    case service_run_alive?(args[:alive_check]) do
      true ->
        {:ok, {:service_already_running, args.name}}

      false ->
        cmd = args.command
        cmd_args = args.args || []
        cd = args[:cd] || "."
        env_file = args[:env_file]

        env = parse_env_file(env_file)

        case System.cmd(cmd, cmd_args, cd: cd, env: env, stderr_to_stdout: true) do
          {_out, 0} -> {:ok, {:service_started, args.name}}
          {out, code} -> {:error, {:service_run_failed, args.name, String.trim(out), code}}
        end
    end
  end

  # Cluster artifact write — touches the host filesystem under
  # <base>/zed/cluster/<id>.config. Synthesises a one-cluster IR
  # to feed the existing Cluster.Config.write!/3 helper instead of
  # duplicating its formatting logic.
  defp execute_step(%Step{type: :cluster_config, action: :create, args: args}, _platform) do
    fake_ir = %Zed.IR{
      name: :__step__,
      pool: nil,
      datasets: [],
      apps: [],
      jails: [],
      zones: [],
      clusters: [
        %Zed.IR.Node{
          id: args.cluster_id,
          type: :cluster,
          config: %{members: args.members},
          deps: []
        }
      ],
      snapshot_config: %{}
    }

    {:ok, [path]} = Zed.Cluster.Config.write!(fake_ir, args.base_mountpoint)
    {:ok, {:cluster_config_written, path}}
  end

  defp execute_step(%Step{} = step, _platform) do
    {:error, {:unknown_step, step.type, step.action}}
  end

  # --- Release Deployment Helpers ---

  defp deploy_release(%{release_path: path, mountpoint: mp}, version)
       when is_binary(path) and is_binary(mp) do
    case Release.deploy(path, version, mp) do
      {:ok, version_dir} -> {:ok, {:deployed, version_dir}}
      {:error, reason} -> {:error, {:release_deploy_failed, reason}}
    end
  end

  defp deploy_release(_args, _version), do: {:ok, :no_tarball}

  # --- Property Stamping Helpers ---

  defp stamp_app_properties(nil, _args, _version), do: :ok

  defp stamp_app_properties(pool_path, args, version) do
    pool_path |> Property.set("version", version)
    pool_path |> Property.set("app", args.app |> to_string())
    args[:node_name] |> maybe_set_property(pool_path, "node_name")
    :ok
  end

  defp maybe_set_property(nil, _pool_path, _key), do: :ok
  defp maybe_set_property(value, pool_path, key), do: Property.set(pool_path, key, to_string(value))

  # --- Jail Helpers ---

  defp create_jail(jail_name, platform) do
    case platform.jail_create(jail_name, %{}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:jail_create_failed, jail_name, reason}}
    end
  end

  defp stamp_jail_properties(%{dataset: nil}), do: :ok

  # alive_check helpers for :service_run.  Currently only :epmd
  # (look up a registered short-name node).
  defp service_run_alive?(nil), do: false

  defp service_run_alive?({:epmd, sname}) do
    case System.cmd("epmd", ["-names"], stderr_to_stdout: true) do
      {out, 0} -> Regex.match?(~r/^name #{Regex.escape(sname)} /m, out)
      _ -> false
    end
  end

  # Parse a "VAR=value\n…" env file into the [{"VAR", "value"}, …]
  # shape System.cmd/3 wants.  Skips blank lines and shell comments.
  defp parse_env_file(nil), do: []

  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reject(fn line ->
          line == "" or String.starts_with?(String.trim(line), "#")
        end)
        |> Enum.map(fn line ->
          [k, v] = String.split(line, "=", parts: 2)
          {String.trim(k), v}
        end)

      _ ->
        []
    end
  end

  # Parse `mount` output to find the source for a given mountpoint.
  # Returns `{:ok, source}` when mounted, `:not_mounted` otherwise.
  defp tarfs_mount_status(mountpoint) do
    case System.cmd("mount", [], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.find_value(:not_mounted, fn line ->
          case Regex.run(~r/^(\S+) on (\S+) \(tarfs/, line) do
            [_, src, ^mountpoint] -> {:ok, src}
            _ -> nil
          end
        end)

      _ ->
        :not_mounted
    end
  end

  # Look for jail_path as the mountpoint (second field of "on <path>")
  # inside the jail's own `mount` table.
  defp jail_mount_present?(jail, jail_path) do
    case Bastille.cmd(jail, ["mount"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case Regex.run(~r/\s+on\s+(\S+)/, line) do
            [_, ^jail_path] -> true
            _ -> false
          end
        end)

      {:error, _} ->
        false
    end
  end

  defp mode_to_string(nil), do: "ro"
  defp mode_to_string(:ro), do: "ro"
  defp mode_to_string(:rw), do: "rw"
  defp mode_to_string(bin) when is_binary(bin), do: bin

  defp enable_service(jail, service) do
    case Bastille.cmd(jail, ["sysrc", "#{service}_enable=YES"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:jail_svc_enable_failed, jail, service, reason}}
    end
  end

  defp start_service_if_needed(jail, service) do
    case Bastille.cmd(jail, ["service", service, "status"]) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        case Bastille.cmd(jail, ["service", service, "start"]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:jail_svc_start_failed, jail, service, reason}}
        end
    end
  end

  defp stamp_jail_properties(%{jail: jail_name, dataset: ds} = args) do
    # Dataset should already have pool prefix from plan
    pool_path = args[:pool_path] || ds

    if pool_path do
      pool_path |> Property.set("jail", to_string(jail_name))
      pool_path |> Property.set("managed", "true")
      args[:contains] |> maybe_set_property(pool_path, "contains")
    end

    :ok
  end
end
