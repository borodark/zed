defmodule Zed.DSLTest do
  use ExUnit.Case, async: true

  describe "DSL compilation" do
    test "minimal deploy compiles to IR" do
      defmodule MinimalDeploy do
        use Zed.DSL

        deploy :minimal, pool: "tank" do
          dataset "apps/hello" do
            mountpoint "/opt/hello"
            compression :lz4
          end

          app :hello do
            dataset "apps/hello"
            version "1.0.0"
            cookie {:env, "COOKIE"}
          end

          snapshots do
            before_deploy true
            keep 3
          end
        end
      end

      ir = MinimalDeploy.__zed_ir__()

      assert ir.name == :minimal
      assert ir.pool == "tank"

      assert length(ir.datasets) == 1
      [ds] = ir.datasets
      assert ds.id == "apps/hello"
      assert ds.type == :dataset
      assert ds.config.mountpoint == "/opt/hello"
      assert ds.config.compression == :lz4

      assert length(ir.apps) == 1
      [app] = ir.apps
      assert app.id == :hello
      assert app.type == :app
      assert app.config.version == "1.0.0"
      assert app.config.dataset == "apps/hello"
      assert app.config.cookie == {:env, "COOKIE"}
      assert app.deps == ["apps/hello"]

      assert ir.snapshot_config.before_deploy == true
      assert ir.snapshot_config.keep == 3
    end

    test "multiple datasets and apps" do
      defmodule MultiDeploy do
        use Zed.DSL

        deploy :multi, pool: "zroot" do
          dataset "apps/web" do
            mountpoint "/opt/web"
          end

          dataset "apps/worker" do
            mountpoint "/opt/worker"
          end

          app :web do
            dataset "apps/web"
            version "2.0.0"
            cookie {:env, "COOKIE"}
          end

          app :worker do
            dataset "apps/worker"
            version "2.0.0"
            cookie {:env, "COOKIE"}
          end
        end
      end

      ir = MultiDeploy.__zed_ir__()

      assert length(ir.datasets) == 2
      assert length(ir.apps) == 2
      assert Enum.map(ir.datasets, & &1.id) == ["apps/web", "apps/worker"]
      assert Enum.map(ir.apps, & &1.id) == [:web, :worker]
    end

    test "app with health checks" do
      defmodule HealthDeploy do
        use Zed.DSL

        deploy :health, pool: "tank" do
          dataset "apps/monitored" do
            mountpoint "/opt/monitored"
          end

          app :monitored do
            dataset "apps/monitored"
            version "1.0.0"
            cookie {:env, "COOKIE"}
            node_name :"monitored@localhost"

            health :beam_ping, timeout: 5_000
            health :http, url: "http://localhost:4000/health", expect: 200
          end
        end
      end

      ir = HealthDeploy.__zed_ir__()
      [app] = ir.apps

      assert length(app.config.health) == 2
      [{:beam_ping, beam_opts}, {:http, http_opts}] = app.config.health
      assert beam_opts[:timeout] == 5_000
      assert http_opts[:url] == "http://localhost:4000/health"
      assert http_opts[:expect] == 200
    end

    test "jail with contains reference" do
      defmodule JailDeploy do
        use Zed.DSL

        deploy :jailed, pool: "tank" do
          dataset "apps/web" do
            mountpoint "/opt/web"
          end

          dataset "jails/web" do
            mountpoint "/jails/web"
          end

          app :web do
            dataset "apps/web"
            version "1.0.0"
            cookie {:env, "COOKIE"}
          end

          jail :web_jail do
            dataset "jails/web"
            contains :web
            ip4 "10.0.1.10/24"
          end
        end
      end

      ir = JailDeploy.__zed_ir__()

      assert length(ir.jails) == 1
      [jail] = ir.jails
      assert jail.id == :web_jail
      assert jail.config.contains == :web
      assert jail.config.ip4 == "10.0.1.10/24"
      assert jail.deps == [:web]
    end

    test "generated functions exist" do
      defmodule FuncCheck do
        use Zed.DSL

        deploy :funcs, pool: "tank" do
          dataset "apps/check" do
            mountpoint "/opt/check"
          end

          app :check do
            dataset "apps/check"
            version "1.0.0"
            cookie {:env, "COOKIE"}
          end
        end
      end

      assert function_exported?(FuncCheck, :__zed_ir__, 0)
      assert function_exported?(FuncCheck, :converge, 0)
      assert function_exported?(FuncCheck, :converge, 1)
      assert function_exported?(FuncCheck, :diff, 0)
      assert function_exported?(FuncCheck, :rollback, 1)
      assert function_exported?(FuncCheck, :status, 0)
    end
  end
end
