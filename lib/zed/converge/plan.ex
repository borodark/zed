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

  # Cluster diff → write the plain-text host-list artifact under the
  # zed dataset. Apps' runtime.exs reads it (zed-dep via
  # Zed.Cluster.Config.load!/1, or zed-less via File.read|split).
  # Members may legitimately be empty (cluster declared but unpopulated)
  # — still write the file so the consumer doesn't see a stale one.
  defp expand_to_steps(%Diff{resource: %{type: :cluster} = node, action: :create}, pool) do
    [
      %Step{
        id: "cluster:config:#{node.id}",
        type: :cluster_config,
        action: :create,
        args: %{
          cluster_id: node.id,
          members: node.config[:members] || [],
          base_mountpoint: cluster_base_mountpoint(pool)
        }
      }
    ]
  end

  defp expand_to_steps(_, _pool), do: []

  # The cluster artifact lives under <base>/zed/cluster/. Default
  # base mountpoint is the canonical /var/db/zed (matches what the
  # bootstrap secrets dataset mounts as); operators can override
  # via app config.
  defp cluster_base_mountpoint(_pool) do
    Application.get_env(:zed, :base_mountpoint, "/var/db/zed")
  end

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

  # Sort: datasets → snapshot → cluster_config → jails → apps → services
  # Within type: install → create → restart
  #
  # cluster_config slots between snapshot and jail because the
  # artifact has to exist BEFORE jails get their nullfs mounts of
  # /var/db/zed; otherwise the first app to boot inside a jail would
  # see a missing artifact. Doesn't depend on any specific dataset
  # being created — only the parent secrets dataset, which the
  # bootstrap step ensures.
  defp sort_by_type(steps) do
    steps
    |> Enum.sort_by(fn step ->
      type_priority = %{
        dataset: 0,
        snapshot: 1,
        cluster_config: 2,
        jail: 3,
        jail_pkg: 4,
        jail_mount: 5,
        app: 6,
        jail_svc: 7,
        service: 8
      }

      action_priority = %{install: 0, create: 1, start: 2, restart: 3}

      {
        Map.get(type_priority, step.type, 99),
        Map.get(action_priority, step.action, 99)
      }
    end)
  end
end
