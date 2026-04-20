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
    config = parse_kv_block(block)

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

  defp opts_to_map([]), do: %{}
  defp opts_to_map([opts]) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(_), do: %{}

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
