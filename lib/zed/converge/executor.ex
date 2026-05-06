defmodule Zed.Converge.Executor do
  @moduledoc """
  Execute a convergence plan step by step.

  Handles `:dataset`, `:app`, `:service`, and `:jail` step types with
  real ZFS/platform operations. Jail sub-steps (`:jail_pkg`,
  `:jail_mount`, `:jail_svc`) are currently stubs returning
  `{:ok, :pending}` — real Bastille wiring lands in S6.

  If any step fails, returns immediately with the failure
  so the caller can trigger rollback.
  """

  alias Zed.Converge.{Plan, Step}
  alias Zed.ZFS.{Dataset, Property}
  alias Zed.Beam.Release

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
      vnet: args.vnet
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

  # --- Jail sub-steps (stubs — real Bastille wiring is S6) ---

  defp execute_step(%Step{type: :jail_pkg, action: :install, args: args}, _platform) do
    {:ok, {:jail_pkg_pending, args.jail, args.packages}}
  end

  defp execute_step(%Step{type: :jail_mount, action: :create, args: args}, _platform) do
    {:ok, {:jail_mount_pending, args.jail, args.host_path, args.jail_path}}
  end

  defp execute_step(%Step{type: :jail_svc, action: :start, args: args}, _platform) do
    {:ok, {:jail_svc_pending, args.jail, args.service}}
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
