defmodule Zed do
  @moduledoc """
  ZFS + Elixir Deploy.

  Declarative BEAM application deployment on FreeBSD and illumos,
  using ZFS as the state store and rollback mechanism.

  ## Usage

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
            node_name :"myapp@\$(hostname -f)"
            cookie {:env, "RELEASE_COOKIE"}
          end
        end
      end

      MyInfra.Prod.converge()
  """

  @version Mix.Project.config()[:version]
  def version, do: @version
end
