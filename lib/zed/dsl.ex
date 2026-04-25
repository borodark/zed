defmodule Zed.DSL do
  @moduledoc """
  Macro-based DSL for declarative BEAM deployment on ZFS.

  Follows the Sim.DSL pattern: `__using__/1` registers module attributes,
  verb macros accumulate declarations, `@before_compile` validates and
  generates `converge/1`, `diff/0`, `rollback/1`, `status/0`.

  ## Example

      defmodule MyInfra.Prod do
        use Zed.DSL

        deploy :prod, pool: "tank" do
          dataset "apps/myapp" do
            mountpoint "/opt/myapp"
            compression :lz4
          end

          app :myapp do
            dataset "apps/myapp"
            version "1.0.0"
            node_name :"myapp@host1"
            cookie {:env, "RELEASE_COOKIE"}
          end

          snapshots do
            before_deploy true
            keep 5
          end
        end
      end

      MyInfra.Prod.converge()
  """

  defmacro __using__(_opts) do
    quote do
      import Zed.DSL, only: [deploy: 3]

      Module.register_attribute(__MODULE__, :zed_datasets, accumulate: true)
      Module.register_attribute(__MODULE__, :zed_apps, accumulate: true)
      Module.register_attribute(__MODULE__, :zed_jails, accumulate: true)
      Module.register_attribute(__MODULE__, :zed_zones, accumulate: true)
      Module.register_attribute(__MODULE__, :zed_clusters, accumulate: true)
      Module.put_attribute(__MODULE__, :zed_deploy_name, nil)
      Module.put_attribute(__MODULE__, :zed_pool, nil)
      Module.put_attribute(__MODULE__, :zed_snapshot_config, %{before_deploy: false, keep: 5})

      @before_compile Zed.DSL
    end
  end

  defmacro deploy(name, opts, do: block) do
    pool = Keyword.fetch!(opts, :pool)

    quote do
      @zed_deploy_name unquote(name)
      @zed_pool unquote(pool)

      import Zed.DSL,
        only: [dataset: 2, app: 2, jail: 2, zone: 2, snapshots: 1, cluster: 2]

      unquote(block)
    end
  end

  # --- Verb Macros ---

  defmacro dataset(path, do: block) do
    config = parse_kv_block(block)

    quote do
      @zed_datasets {unquote(path), unquote(Macro.escape(config))}
    end
  end

  defmacro app(name, do: block) do
    config = parse_app_block(block)

    quote do
      @zed_apps {unquote(name), unquote(Macro.escape(config))}
    end
  end

  defmacro jail(name, do: block) do
    config = parse_jail_block(block)

    quote do
      @zed_jails {unquote(name), unquote(Macro.escape(config))}
    end
  end

  defmacro zone(name, do: block) do
    config = parse_kv_block(block)

    quote do
      @zed_zones {unquote(name), unquote(Macro.escape(config))}
    end
  end

  defmacro snapshots(do: block) do
    config = parse_kv_block(block)

    quote do
      @zed_snapshot_config unquote(Macro.escape(config))
    end
  end

  defmacro cluster(name, do: block) do
    config = parse_kv_block(block)

    quote do
      @zed_clusters {unquote(name), unquote(Macro.escape(config))}
    end
  end

  # --- @before_compile: validate IR + generate functions ---

  defmacro __before_compile__(env) do
    datasets = Module.get_attribute(env.module, :zed_datasets) |> Enum.reverse()
    apps = Module.get_attribute(env.module, :zed_apps) |> Enum.reverse()
    jails = Module.get_attribute(env.module, :zed_jails) |> Enum.reverse()
    zones = Module.get_attribute(env.module, :zed_zones) |> Enum.reverse()
    clusters = Module.get_attribute(env.module, :zed_clusters) |> Enum.reverse()
    deploy_name = Module.get_attribute(env.module, :zed_deploy_name)
    pool = Module.get_attribute(env.module, :zed_pool)
    snapshot_config = Module.get_attribute(env.module, :zed_snapshot_config)

    # Desugar inline apps: jail config with :app key becomes a top-level
    # app + contains reference on the jail.
    {jails, inline_apps} = extract_inline_apps(jails)
    apps = apps ++ inline_apps

    ir = build_ir(deploy_name, pool, datasets, apps, jails, zones, clusters, snapshot_config)

    # Validate at compile time
    Zed.IR.Validate.run!(ir)

    escaped_ir = Macro.escape(ir)

    quote do
      @doc "Returns the deployment IR for this module."
      def __zed_ir__, do: unquote(escaped_ir)

      @doc "Run the full convergence loop: diff → plan → apply → verify."
      def converge(opts \\ []) do
        Zed.Converge.run(__zed_ir__(), opts)
      end

      @doc "Show what would change without applying."
      def diff do
        Zed.Converge.Diff.compute(__zed_ir__())
      end

      @doc "Rollback to a previous version or snapshot."
      def rollback(target) do
        Zed.Converge.rollback(__zed_ir__(), target)
      end

      @doc "Read current deployment state from ZFS properties."
      def status do
        Zed.State.read(__zed_ir__())
      end
    end
  end

  # --- Private: AST Parsing ---

  # Parse a do-block of `key value` calls into a map.
  defp parse_kv_block({:__block__, _, statements}) do
    Enum.reduce(statements, %{}, &parse_kv_statement/2)
  end

  defp parse_kv_block(single) do
    parse_kv_statement(single, %{})
  end

  defp parse_kv_statement({key, _, [value]}, acc) when is_atom(key) do
    Map.put(acc, key, normalize_value(value))
  end

  defp parse_kv_statement({key, _, nil}, acc) when is_atom(key) do
    Map.put(acc, key, true)
  end

  defp parse_kv_statement(_, acc), do: acc

  # Elixir represents literal 3+ tuples in the AST as `{:{}, meta, args}`,
  # while 2-tuples are themselves (the AST of `{a, b}` is `{a, b}`). When
  # DSL authors write `{:secret, slot, field, opts}`, the macro receives
  # the AST form; Macro.escape later converts back to a runtime tuple
  # only if we normalise here first.
  defp normalize_value({:{}, _, args}) when is_list(args) do
    args |> Enum.map(&normalize_value/1) |> List.to_tuple()
  end

  defp normalize_value({:%{}, _, args}) when is_list(args) do
    Map.new(args, fn {k, v} -> {normalize_value(k), normalize_value(v)} end)
  end

  defp normalize_value(other), do: other

  # Parse app block — like kv but accumulates :health entries.
  defp parse_app_block({:__block__, _, statements}) do
    Enum.reduce(statements, %{health: []}, &parse_app_statement/2)
  end

  defp parse_app_block(single) do
    parse_app_statement(single, %{health: []})
  end

  defp parse_app_statement({:health, _, [type | opts]}, acc) do
    check = {type, opts_to_map(opts)}
    Map.update!(acc, :health, fn checks -> checks ++ [check] end)
  end

  defp parse_app_statement({key, _, [value]}, acc) when is_atom(key) do
    Map.put(acc, key, normalize_value(value))
  end

  defp parse_app_statement(_, acc), do: acc

  # Parse jail block — handles nested app, service, nullfs_mount, and
  # two-arg dataset forms. Simple key-value falls through to parse_kv_statement.
  defp parse_jail_block({:__block__, _, statements}) do
    Enum.reduce(statements, %{services: [], mounts: []}, &parse_jail_statement/2)
  end

  defp parse_jail_block(single) do
    parse_jail_statement(single, %{services: [], mounts: []})
  end

  # app :name do ... end — inline app nested inside jail
  defp parse_jail_statement({:app, _, [name, [do: inner_block]]}, acc) do
    app_config = parse_app_block(inner_block)
    Map.put(acc, :app, {name, app_config})
  end

  # service :name, opts  OR  service :name (no opts)
  defp parse_jail_statement({:service, _, [name | opts]}, acc) do
    svc = {name, opts_to_map(opts)}
    Map.update!(acc, :services, fn svcs -> svcs ++ [svc] end)
  end

  # nullfs_mount path, into: target, mode: :ro
  defp parse_jail_statement({:nullfs_mount, _, [path | opts]}, acc) do
    mount = {path, opts_to_map(opts)}
    Map.update!(acc, :mounts, fn ms -> ms ++ [mount] end)
  end

  # dataset "data/pg", mount_in_jail: "/var/db/postgres" — two-arg form
  defp parse_jail_statement({:dataset, _, [path | opts]}, acc) when opts != [] do
    ds = {path, opts_to_map(opts)}
    Map.update(acc, :datasets, [ds], fn dss -> dss ++ [ds] end)
  end

  # Everything else: regular key-value (packages, release, depends_on, ip4, etc.)
  defp parse_jail_statement(other, acc) do
    parse_kv_statement(other, acc)
  end

  defp opts_to_map([]), do: %{}
  defp opts_to_map([opts]) when is_list(opts), do: Map.new(opts, &normalize_opt/1)
  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts, &normalize_opt/1)
  defp opts_to_map(_), do: %{}

  defp normalize_opt({k, v}), do: {k, normalize_value(v)}

  # --- Private: Inline App Desugaring ---

  # Jails with an inline `app :name do...end` desugar into a top-level
  # app + `contains` on the jail. The app inherits the jail's dataset
  # if not explicitly set.
  defp extract_inline_apps(jails) do
    {updated_jails, extra_apps} =
      Enum.reduce(jails, {[], []}, fn {jail_name, config}, {js, as} ->
        case Map.pop(config, :app) do
          {nil, config} ->
            {[{jail_name, config} | js], as}

          {{app_name, app_config}, config} ->
            config = Map.put(config, :contains, app_name)
            app_config = Map.put_new(app_config, :dataset, config[:dataset])
            {[{jail_name, config} | js], [{app_name, app_config} | as]}
        end
      end)

    {Enum.reverse(updated_jails), Enum.reverse(extra_apps)}
  end

  # --- Private: IR Construction ---

  defp build_ir(name, pool, datasets, apps, jails, zones, clusters, snapshot_config) do
    %Zed.IR{
      name: name,
      pool: pool,
      datasets: Enum.map(datasets, &build_dataset_node/1),
      apps: Enum.map(apps, &build_app_node/1),
      jails: Enum.map(jails, &build_jail_node/1),
      zones: Enum.map(zones, &build_zone_node/1),
      clusters: Enum.map(clusters, &build_cluster_node/1),
      snapshot_config: snapshot_config
    }
  end

  defp build_dataset_node({path, config}) do
    %Zed.IR.Node{id: path, type: :dataset, config: config}
  end

  defp build_app_node({name, config}) do
    deps = if config[:dataset], do: [config[:dataset]], else: []
    %Zed.IR.Node{id: name, type: :app, config: config, deps: deps}
  end

  defp build_jail_node({name, config}) do
    deps = if config[:contains], do: [config[:contains]], else: []
    %Zed.IR.Node{id: name, type: :jail, config: config, deps: deps}
  end

  defp build_zone_node({name, config}) do
    deps = if config[:contains], do: [config[:contains]], else: []
    %Zed.IR.Node{id: name, type: :zone, config: config, deps: deps}
  end

  defp build_cluster_node({name, config}) do
    %Zed.IR.Node{id: name, type: :cluster, config: config}
  end
end
