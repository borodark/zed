defmodule Zed.Converge.Plan do
  @moduledoc """
  Build an ordered execution plan from a diff.

  Steps are topologically sorted: datasets before apps,
  apps before services, snapshots before mutations.
  """

  alias Zed.Converge.{Diff, Step}

  defstruct steps: [], dry_run: false

  @type t :: %__MODULE__{
          steps: [Step.t()],
          dry_run: boolean()
        }

  @doc "Build an execution plan from diff entries."
  def from_diff(diff_entries, opts \\ []) do
    pool = Keyword.get(opts, :pool)

    steps =
      diff_entries
      |> Enum.flat_map(&expand_to_steps(&1, pool))
      |> sort_by_type()

    %__MODULE__{
      steps: steps,
      dry_run: Keyword.get(opts, :dry_run, false)
    }
  end

  # --- Step Expansion ---

  defp expand_to_steps(%Diff{resource: %{type: :dataset} = node, action: :create}, pool) do
    pool_path = build_pool_path(pool, node.id)

    props =
      node.config
      |> Map.take([:mountpoint, :compression, :quota, :recordsize])
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    [
      %Step{
        id: "dataset:create:#{node.id}",
        type: :dataset,
        action: :create,
        args: %{path: node.id, pool_path: pool_path, properties: props}
      }
    ]
  end

  defp expand_to_steps(%Diff{resource: %{type: :dataset} = node, action: :update, changes: changes}, pool) do
    pool_path = build_pool_path(pool, node.id)

    changes
    |> Enum.map(fn {prop, _old, new} ->
      %Step{
        id: "dataset:set:#{node.id}:#{prop}",
        type: :dataset,
        action: :update,
        args: %{
          path: node.id,
          pool_path: pool_path,
          property: to_string(prop),
          value: to_string(new)
        }
      }
    end)
  end

  defp expand_to_steps(%Diff{resource: %{type: :app} = node, action: action}, pool)
       when action in [:create, :update] do
    %{config: config, id: app_id} = node
    ds = config[:dataset]
    pool_path = build_pool_path(pool, ds)
    mountpoint = config[:mountpoint] || derive_mountpoint(pool_path)
    service_name = config[:service] || to_string(app_id)

    [
      build_app_deploy_step(node, pool_path, mountpoint),
      build_service_install_step(app_id, service_name, mountpoint, config),
      build_service_restart_step(app_id, service_name)
    ]
  end

  defp expand_to_steps(%Diff{resource: %{type: :jail} = node, action: action}, pool)
       when action in [:create, :update] do
    %{config: config, id: jail_id} = node
    ds = config[:dataset]
    pool_path = build_pool_path(pool, ds)
    mountpoint = config[:mountpoint] || derive_mountpoint(pool_path)

    [
      build_jail_install_step(jail_id, config, mountpoint),
      build_jail_create_step(jail_id, config, ds)
    ]
  end

  defp expand_to_steps(_, _pool), do: []

  # --- Step Builders: Jails ---

  defp build_jail_install_step(jail_id, config, mountpoint) do
    %Step{
      id: "jail:install:#{jail_id}",
      type: :jail,
      action: :install,
      args: %{
        jail: jail_id,
        path: mountpoint,
        hostname: config[:hostname] || "#{jail_id}.local",
        ip4: config[:ip4],
        ip6: config[:ip6],
        vnet: config[:vnet] || false
      },
      deps: config[:dataset] |> maybe_dataset_dep()
    }
  end

  defp build_jail_create_step(jail_id, config, ds) do
    %Step{
      id: "jail:create:#{jail_id}",
      type: :jail,
      action: :create,
      args: %{
        jail: jail_id,
        dataset: ds,
        contains: config[:contains]
      },
      deps: ["jail:install:#{jail_id}"]
    }
  end

  # --- Step Builders: Apps ---

  defp build_app_deploy_step(%{id: app_id, config: config}, pool_path, mountpoint) do
    %Step{
      id: "app:deploy:#{app_id}",
      type: :app,
      action: :create,
      args: %{
        app: app_id,
        version: config[:version],
        dataset: config[:dataset],
        pool_path: pool_path,
        mountpoint: mountpoint,
        release_path: config[:release_path],
        env_file: config[:env_file],
        node_name: config[:node_name],
        cookie: config[:cookie]
      },
      deps: config[:dataset] |> maybe_dataset_dep()
    }
  end

  defp build_service_install_step(app_id, service_name, mountpoint, config) do
    %Step{
      id: "service:install:#{app_id}",
      type: :service,
      action: :install,
      args: %{
        service: service_name,
        mountpoint: mountpoint,
        user: config[:user] || to_string(app_id),
        env_file: config[:env_file]
      },
      deps: ["app:deploy:#{app_id}"]
    }
  end

  defp build_service_restart_step(app_id, service_name) do
    %Step{
      id: "service:restart:#{app_id}",
      type: :service,
      action: :restart,
      args: %{service: service_name},
      deps: ["service:install:#{app_id}"]
    }
  end

  # --- Helpers ---

  defp build_pool_path(nil, id), do: id
  defp build_pool_path(_pool, nil), do: nil
  defp build_pool_path(pool, id), do: "#{pool}/#{id}"

  defp derive_mountpoint(nil), do: nil
  defp derive_mountpoint(pool_path), do: "/#{pool_path}"

  defp maybe_dataset_dep(nil), do: []
  defp maybe_dataset_dep(ds), do: ["dataset:create:#{ds}"]

  # Sort: datasets → jails → apps → services
  # Within type: install → create → restart
  defp sort_by_type(steps) do
    steps
    |> Enum.sort_by(fn step ->
      type_priority = %{dataset: 0, snapshot: 1, jail: 2, app: 3, service: 4}
      action_priority = %{install: 0, create: 1, restart: 2}

      {
        Map.get(type_priority, step.type, 99),
        Map.get(action_priority, step.action, 99)
      }
    end)
  end
end
