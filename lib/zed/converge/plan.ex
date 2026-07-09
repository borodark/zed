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

    # Build an app_id -> jail_id map from every jail diff's `contains`
    # reference. Used at :app expansion time to route contained apps
    # to their jail-side steps instead of host-side deploys.
    contains_map = build_contains_map(diff_entries)

    steps =
      diff_entries
      |> Enum.flat_map(&expand_to_steps(&1, pool, contains_map))
      |> sort_by_type()

    %__MODULE__{
      steps: steps,
      dry_run: Keyword.get(opts, :dry_run, false)
    }
  end

  defp build_contains_map(diffs) do
    diffs
    |> Enum.filter(fn
      %Diff{resource: %{type: :jail}} -> true
      _ -> false
    end)
    |> Enum.reduce(%{}, fn %Diff{resource: jail}, acc ->
      case jail.config[:contains] do
        nil -> acc
        app_id -> Map.put(acc, app_id, jail.id)
      end
    end)
  end

  # --- Step Expansion ---

  defp expand_to_steps(%Diff{resource: %{type: :dataset} = node, action: :create}, pool, _contains_map) do
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

  defp expand_to_steps(%Diff{resource: %{type: :dataset} = node, action: :update, changes: changes}, pool, _contains_map) do
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

  defp expand_to_steps(%Diff{resource: %{type: :app} = node, action: action}, pool, contains_map)
       when action in [:create, :update] do
    %{config: config, id: app_id} = node
    ds = config[:dataset]
    pool_path = build_pool_path(pool, ds)
    mountpoint = config[:mountpoint] || derive_mountpoint(pool_path)
    service_name = config[:service] || to_string(app_id)

    case Map.get(contains_map, app_id) do
      nil ->
        # Host-side app: existing deploy + rc.d on the host.
        [
          build_app_deploy_step(node, pool_path, mountpoint),
          build_service_install_step(app_id, service_name, mountpoint, config),
          build_service_restart_step(app_id, service_name)
        ]

      jail_id ->
        # Jail-contained app: release into jail rootfs, rc.d inside
        # jail, service start via the Path B jail_svc plumbing. The
        # host-side deploy + rc.d + restart steps are skipped.
        [
          build_jail_app_deploy_step(app_id, jail_id, node),
          build_jail_service_install_step(app_id, jail_id, service_name, config),
          build_jail_app_svc_step(app_id, jail_id, service_name)
        ]
    end
  end

  defp expand_to_steps(%Diff{resource: %{type: :jail} = node, action: action}, pool, _contains_map)
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
    |> Kernel.++(build_jail_data_mount_steps(jail_id, config, pool))
    |> Kernel.++(build_jail_file_steps(jail_id, config))
    |> Kernel.++(build_jail_setup_steps(jail_id, config))
    |> Kernel.++(build_jail_svc_steps(jail_id, config))
  end

  # Cluster diff → write the plain-text host-list artifact under the
  # zed dataset. Apps' runtime.exs reads it (zed-dep via
  # Zed.Cluster.Config.load!/1, or zed-less via File.read|split).
  # Members may legitimately be empty (cluster declared but unpopulated)
  # — still write the file so the consumer doesn't see a stale one.
  defp expand_to_steps(%Diff{resource: %{type: :cluster} = node, action: :create}, pool, _contains_map) do
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

  defp expand_to_steps(%Diff{resource: %{type: :tarfs} = node, action: :create}, _pool, _contains_map) do
    [
      %Step{
        id: "tarfs:mount:#{node.id}",
        type: :tarfs,
        action: :mount,
        args: %{
          name: node.id,
          tar_path: node.config[:tar_path],
          mount: node.config[:mount]
        }
      }
    ]
  end

  defp expand_to_steps(%Diff{resource: %{type: :file} = node, action: :create}, _pool, _contains_map) do
    [
      %Step{
        id: "file:write:#{node.id}",
        type: :file,
        action: :write,
        args: %{
          path: node.id,
          content: node.config[:content] || "",
          mode: node.config[:mode],
          owner: node.config[:owner],
          group: node.config[:group]
        }
      }
    ]
  end

  defp expand_to_steps(%Diff{resource: %{type: :service_run} = node, action: :create}, _pool, _contains_map) do
    [
      %Step{
        id: "service_run:start:#{node.id}",
        type: :service_run,
        action: :start,
        args: %{
          name: node.id,
          command: node.config[:command],
          args: node.config[:args] || [],
          cd: node.config[:cd],
          env_file: node.config[:env_file],
          alive_check: node.config[:alive_check]
        }
      }
    ]
  end

  defp expand_to_steps(_, _pool, _contains_map), do: []

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
        vnet: config[:vnet] || false,
        release: config[:release],
        jail_params: config[:jail_params] || []
      },
      deps: config[:dataset] |> maybe_dataset_dep()
    }
  end

  defp build_jail_create_step(jail_id, config, ds) do
    upstream_deps =
      config
      |> depends_on_list()
      |> Enum.map(&"jail:create:#{&1}")

    %Step{
      id: "jail:create:#{jail_id}",
      type: :jail,
      action: :create,
      args: %{
        jail: jail_id,
        dataset: ds,
        contains: config[:contains]
      },
      deps: ["jail:install:#{jail_id}" | upstream_deps]
    }
  end

  # Normalize depends_on to a list of atoms. Validation guarantees
  # each entry references a declared jail.
  defp depends_on_list(config) do
    case config[:depends_on] do
      nil -> []
      dep when is_atom(dep) -> [dep]
      deps when is_list(deps) -> deps
    end
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

  # --- Step Builders: Path C jail-contained apps ---

  # Extract release tarball into <jails_dir>/<jail>/root/opt/<app>/
  # and symlink `current` to the fresh version. The `release_path`
  # arg is the host path to the tarball; executor reads it there and
  # writes into the jail rootfs from the host side (nullfs-friendly).
  defp build_jail_app_deploy_step(app_id, jail_id, %{config: config}) do
    %Step{
      id: "jail:app:#{jail_id}:#{app_id}",
      type: :jail_app,
      action: :deploy,
      args: %{
        jail: jail_id,
        app: app_id,
        version: config[:version],
        release_path: config[:release_path],
        mount_in_jail: config[:mount_in_jail] || "/opt/#{app_id}",
        node_name: config[:node_name],
        cookie: config[:cookie],
        env_file: config[:env_file]
      },
      deps: ["jail:create:#{jail_id}"]
    }
  end

  # Write an rc.d script for the app inside the jail rootfs. Path B's
  # :jail_svc :start step then enables + starts it.
  defp build_jail_service_install_step(app_id, jail_id, service_name, config) do
    %Step{
      id: "jail:service:#{jail_id}:#{app_id}",
      type: :jail_service,
      action: :install,
      args: %{
        jail: jail_id,
        service: service_name,
        mount_in_jail: config[:mount_in_jail] || "/opt/#{app_id}",
        user: config[:user] || to_string(app_id),
        env_file: config[:env_file]
      },
      deps: ["jail:app:#{jail_id}:#{app_id}"]
    }
  end

  # Reuse the Path B :jail_svc :start executor clause — sysrc enable
  # + service start inside the jail via bastille cmd.
  defp build_jail_app_svc_step(app_id, jail_id, service_name) do
    %Step{
      id: "jail:svc:#{jail_id}:#{service_name}",
      type: :jail_svc,
      action: :start,
      args: %{jail: jail_id, service: service_name, env: nil},
      deps: ["jail:service:#{jail_id}:#{app_id}"]
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

  # Two-arg dataset form inside a jail block:
  #   dataset "data/pg", mount_in_jail: "/var/db/postgres"
  # → jail.config[:datasets] = [{path, %{mount_in_jail: "/..."}}]
  #
  # The data dataset lives at /<pool>/<path> on the host; nullfs-mount
  # it rw into the jail at the requested target so the service picks
  # up persistent state on restart.
  defp build_jail_data_mount_steps(jail_id, %{datasets: datasets}, pool)
       when is_list(datasets) and datasets != [] do
    datasets
    |> Enum.with_index()
    |> Enum.flat_map(fn {{path, opts}, idx} ->
      case opts[:mount_in_jail] do
        nil ->
          []

        jail_path ->
          host_path = "/#{pool}/#{path}"

          [
            %Step{
              id: "jail:datamount:#{jail_id}:#{idx}",
              type: :jail_mount,
              action: :create,
              args: %{
                jail: jail_id,
                host_path: host_path,
                jail_path: jail_path,
                mode: :rw
              },
              deps: ["jail:create:#{jail_id}", "dataset:create:#{path}"]
            }
          ]
      end
    end)
  end

  defp build_jail_data_mount_steps(_jail_id, _config, _pool), do: []

  defp build_jail_file_steps(jail_id, %{jail_files: files})
       when is_list(files) and files != [] do
    files
    |> Enum.with_index()
    |> Enum.map(fn {{path, opts}, idx} ->
      %Step{
        id: "jail:file:#{jail_id}:#{idx}",
        type: :jail_file,
        action: :create,
        args: %{
          jail: jail_id,
          path: path,
          content: opts[:content] || "",
          mode: opts[:mode]
        },
        deps: ["jail:create:#{jail_id}"]
      }
    end)
  end

  defp build_jail_file_steps(_jail_id, _config), do: []

  defp build_jail_setup_steps(jail_id, %{setup: ops}) when is_list(ops) and ops != [] do
    [
      %Step{
        id: "jail:setup:#{jail_id}",
        type: :jail_setup,
        action: :run,
        args: %{jail: jail_id, ops: ops},
        deps: ["jail:create:#{jail_id}"]
      }
    ]
  end

  defp build_jail_setup_steps(_jail_id, _config), do: []

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
    depth = topo_depth(steps)

    steps
    |> Enum.sort_by(fn step ->
      type_priority = %{
        dataset: 0,
        snapshot: 1,
        cluster_config: 2,
        tarfs: 2,
        jail: 3,
        jail_pkg: 4,
        jail_mount: 5,
        jail_file: 6,
        jail_setup: 6,
        jail_app: 6,
        jail_service: 6,
        app: 6,
        file: 6,
        jail_svc: 7,
        service: 8,
        service_run: 9
      }

      action_priority = %{
        install: 0,
        deploy: 0,
        create: 1,
        start: 2,
        restart: 3,
        mount: 1,
        write: 1
      }

      {
        Map.get(type_priority, step.type, 99),
        Map.get(action_priority, step.action, 99),
        Map.get(depth, step.id, 0)
      }
    end)
  end

  # Compute a topological depth (longest-path from a root) for each
  # step id from its declared `deps`. Depth is used as a tie-breaker
  # inside sort_by_type/1 so steps at the same (type, action)
  # bucket that reference each other via `deps` execute in the right
  # order — most importantly, jail_A's :create waits for jail_B's
  # :create when jail_A `depends_on :jail_B`.
  #
  # Steps whose deps reference an id not in `steps` (cross-bucket
  # deps like "jail:install:X" from the same jail) don't influence
  # depth here — those deps still document intent and are honored by
  # the type/action bucketing which places install before create.
  defp topo_depth(steps) do
    by_id = Map.new(steps, fn s -> {s.id, s} end)

    Enum.reduce(steps, %{}, fn step, memo ->
      {memo2, _d} = compute_depth(step.id, by_id, memo)
      memo2
    end)
  end

  defp compute_depth(id, by_id, memo) do
    case Map.fetch(memo, id) do
      {:ok, d} ->
        {memo, d}

      :error ->
        case Map.fetch(by_id, id) do
          :error ->
            {Map.put(memo, id, 0), 0}

          {:ok, step} ->
            {memo2, max_parent} =
              Enum.reduce(step.deps, {memo, -1}, fn dep_id, {m, mx} ->
                {m2, d} = compute_depth(dep_id, by_id, m)
                {m2, max(mx, d)}
              end)

            d = max_parent + 1
            {Map.put(memo2, id, d), d}
        end
    end
  end
end
