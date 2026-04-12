defmodule Zed.Examples.TestDeploy do
  @moduledoc """
  Example deployment configuration for testing against jeff/zed-test.

  Usage:
      iex> Zed.Examples.TestDeploy.diff()
      iex> Zed.Examples.TestDeploy.converge(dry_run: true)
      iex> Zed.Examples.TestDeploy.converge()
      iex> Zed.Examples.TestDeploy.status()
  """

  use Zed.DSL

  deploy :test_deploy, pool: "jeff" do
    dataset "zed-test/example-app" do
      compression :lz4
    end

    app :example_app do
      dataset "zed-test/example-app"
      version "0.1.0"
      node_name :"example@localhost"
      cookie {:env, "RELEASE_COOKIE"}
    end

    snapshots do
      before_deploy true
      keep 3
    end
  end
end
