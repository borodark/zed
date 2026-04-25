defmodule Zed.Converge.Plan do
  @moduledoc """
  Build an ordered execution plan from a diff.

  Steps are topologically sorted by type priority:

      dataset → snapshot → jail → jail_pkg → jail_mount → app → jail_svc → service

  Within each type, actions sort: install → create → start → restart.

  Jail diffs expand into up to five sub-steps: `jail:install` (write
  jail.conf), `jail:create` (start jail), `jail:pkg` (install packages),
  `jail:mount` (nullfs mounts), and `jail:svc` (start services).
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
    |> Kernel.++(build_jail_pkg_steps(jail_id, config))
    |> Kernel.++(build_jail_mount_steps(jail_id, config))
    |> Kernel.++(build_jail_svc_steps(jail_id, config))
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

  # --- Step Builders: Jail sub-steps ---

  defp build_jail_pkg_steps(jail_id, %{packages: pkgs}) when is_list(pkgs) and pkgs != [] do
    [
      %Step{
        id: "jail:pkg:#{jail_id}",
        type: :jail_pkg,
        action: :install,
        args: %{jail: jail_id, packages: pkgs},
        deps: ["jail:create:#{jail_id}"]
      }
    ]
  end

  defp build_jail_pkg_steps(_jail_id, _config), do: []

  defp build_jail_mount_steps(jail_id, %{mounts: mounts}) when is_list(mounts) and mounts != [] do
    mounts
    |> Enum.with_index()
    |> Enum.map(fn {{path, opts}, idx} ->
      %Step{
        id: "jail:mount:#{jail_id}:#{idx}",
        type: :jail_mount,
        action: :create,
        args: %{jail: jail_id, host_path: path, jail_path: opts[:into], mode: opts[:mode]},
        deps: ["jail:create:#{jail_id}"]
      }
    end)
  end

  defp build_jail_mount_steps(_jail_id, _config), do: []

  defp build_jail_svc_steps(jail_id, %{services: svcs}) when is_list(svcs) and svcs != [] do
    # Services depend on packages (if any) being installed first
    pkg_dep =
      case svcs do
        _ -> ["jail:create:#{jail_id}"]
      end

    svcs
    |> Enum.map(fn {name, opts} ->
      %Step{
        id: "jail:svc:#{jail_id}:#{name}",
        type: :jail_svc,
        action: :start,
        args: %{jail: jail_id, service: name, env: opts[:env]},
        deps: pkg_dep
      }
    end)
  end

  defp build_jail_svc_steps(_jail_id, _config), do: []

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
      type_priority = %{dataset: 0, snapshot: 1, jail: 2, jail_pkg: 3, jail_mount: 4, app: 5, jail_svc: 6, service: 7}
      action_priority = %{install: 0, create: 1, start: 2, restart: 3}

      {
        Map.get(type_priority, step.type, 99),
        Map.get(action_priority, step.action, 99)
      }
    end)
  end
end
