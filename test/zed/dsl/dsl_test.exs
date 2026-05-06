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

    test "DSL compiles with :secret cookie reference" do
      defmodule SecretRefCompile do
        use Zed.DSL

        deploy :sref, pool: "tank" do
          dataset "apps/web" do
            mountpoint "/opt/web"
          end

          app :web do
            dataset "apps/web"
            version "1.0.0"
            cookie {:secret, :beam_cookie}
          end
        end
      end

      [app] = SecretRefCompile.__zed_ir__().apps
      assert app.config.cookie == {:secret, :beam_cookie}
    end

    test "DSL compilation fails with unknown secret slot" do
      assert_raise Zed.ValidationError, ~r/unknown secret slot :ghost_slot/, fn ->
        defmodule SecretRefBadSlot do
          use Zed.DSL

          deploy :bad, pool: "tank" do
            dataset "apps/web" do
              mountpoint "/opt/web"
            end

            app :web do
              dataset "apps/web"
              version "1.0.0"
              cookie {:secret, :ghost_slot}
            end
          end
        end
      end
    end

    test "DSL compilation fails with pending storage mode (Layer D6)" do
      assert_raise Zed.ValidationError,
                   ~r/probnik_vault is not yet implemented, pending Layer D6/,
                   fn ->
                     defmodule SecretRefPendingStorage do
                       use Zed.DSL

                       deploy :pending, pool: "tank" do
                         dataset "apps/web" do
                           mountpoint "/opt/web"
                         end

                         app :web do
                           dataset "apps/web"
                           version "1.0.0"
                           cookie {:secret, :beam_cookie, :value, storage: :probnik_vault}
                         end
                       end
                     end
                   end
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

    test "jail with packages and release" do
      defmodule PkgJailDeploy do
        use Zed.DSL

        deploy :pkg_jail, pool: "tank" do
          dataset "jails/pg" do
            compression :lz4
          end

          jail :pg do
            dataset "jails/pg"
            ip4 "10.17.89.20/24"
            release "15.0-RELEASE"
            packages ["postgresql16-server", "postgresql16-contrib"]
          end
        end
      end

      ir = PkgJailDeploy.__zed_ir__()
      [jail] = ir.jails
      assert jail.id == :pg
      assert jail.config.packages == ["postgresql16-server", "postgresql16-contrib"]
      assert jail.config.release == "15.0-RELEASE"
    end

    test "jail with service" do
      defmodule SvcJailDeploy do
        use Zed.DSL

        deploy :svc_jail, pool: "tank" do
          dataset "jails/pg" do
            compression :lz4
          end

          jail :pg do
            dataset "jails/pg"
            ip4 "10.17.89.20/24"
            service :postgresql, env: %{"PGDATA" => "/var/db/postgres/16/data"}
          end
        end
      end

      ir = SvcJailDeploy.__zed_ir__()
      [jail] = ir.jails
      assert [{:postgresql, opts}] = jail.config.services
      assert opts.env == %{"PGDATA" => "/var/db/postgres/16/data"}
    end

    test "jail with nullfs_mount" do
      defmodule MountJailDeploy do
        use Zed.DSL

        deploy :mount_jail, pool: "tank" do
          dataset "jails/zedweb" do
            compression :lz4
          end

          jail :zedweb do
            dataset "jails/zedweb"
            ip4 "10.17.89.10/24"
            nullfs_mount "/var/run/zed", into: "/host_run_zed", mode: :ro
          end
        end
      end

      ir = MountJailDeploy.__zed_ir__()
      [jail] = ir.jails
      assert [{"/var/run/zed", opts}] = jail.config.mounts
      assert opts.into == "/host_run_zed"
      assert opts.mode == :ro
    end

    test "jail with inline app desugars into top-level app + contains" do
      defmodule InlineAppJailDeploy do
        use Zed.DSL

        deploy :inline_app, pool: "tank" do
          dataset "jails/web" do
            compression :lz4
          end

          jail :web do
            dataset "jails/web"
            ip4 "10.17.89.10/24"
            packages ["erlang-runtime27"]

            app :webserver do
              version "1.0.0"
              cookie {:env, "COOKIE"}
              health :http, url: "http://10.17.89.10:4000/health", expect: 200
            end
          end
        end
      end

      ir = InlineAppJailDeploy.__zed_ir__()

      # Jail gets contains set automatically
      [jail] = ir.jails
      assert jail.config.contains == :webserver

      # App is promoted to top-level with jail's dataset
      [app] = ir.apps
      assert app.id == :webserver
      assert app.config.version == "1.0.0"
      assert app.config.dataset == "jails/web"
      assert app.config.cookie == {:env, "COOKIE"}
      assert [{:http, http_opts}] = app.config.health
      assert http_opts[:url] == "http://10.17.89.10:4000/health"
    end

    test "jail with depends_on" do
      defmodule DepsJailDeploy do
        use Zed.DSL

        deploy :deps_jail, pool: "tank" do
          dataset "jails/pg" do
            compression :lz4
          end

          dataset "jails/app" do
            compression :lz4
          end

          jail :pg do
            dataset "jails/pg"
            ip4 "10.17.89.20/24"
          end

          jail :myapp do
            dataset "jails/app"
            ip4 "10.17.89.11/24"
            depends_on :pg
          end
        end
      end

      ir = DepsJailDeploy.__zed_ir__()
      myapp = Enum.find(ir.jails, &(&1.id == :myapp))
      assert myapp.config.depends_on == :pg
    end

    test "jail with dataset mount_in_jail" do
      defmodule DatasetMountJailDeploy do
        use Zed.DSL

        deploy :ds_mount, pool: "tank" do
          dataset "jails/pg" do
            compression :lz4
          end

          dataset "data/pg" do
            compression :lz4
          end

          jail :pg do
            dataset "jails/pg"
            ip4 "10.17.89.20/24"
            dataset "data/pg", mount_in_jail: "/var/db/postgres"
          end
        end
      end

      ir = DatasetMountJailDeploy.__zed_ir__()
      [jail] = ir.jails
      assert [{"data/pg", opts}] = jail.config.datasets
      assert opts.mount_in_jail == "/var/db/postgres"
    end
  end
end
