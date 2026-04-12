defmodule Zed.Examples.JailDeploy do
  @moduledoc """
  Example deployment with jails.

  Demonstrates:
  - Jail dataset creation
  - Jail configuration generation
  - App running inside jail (contains directive)

  Usage:
      iex> Zed.Examples.JailDeploy.diff()
      iex> Zed.Examples.JailDeploy.converge(dry_run: true)
  """

  use Zed.DSL

  deploy :jailed_apps, pool: "jeff" do
    # Dataset for app code (shared or per-app)
    dataset "zed-test/apps/trading" do
      compression :lz4
    end

    # Dataset for jail root filesystem
    dataset "zed-test/jails/trading" do
      compression :lz4
    end

    # The app that will run inside the jail
    app :trading do
      dataset "zed-test/apps/trading"
      version "1.0.0"
      node_name :"trading@trading-jail.local"
      cookie {:env, "RELEASE_COOKIE"}
    end

    # Jail containing the trading app
    jail :trading_jail do
      dataset "zed-test/jails/trading"
      hostname "trading-jail.local"
      ip4 "10.0.1.100/24"
      contains :trading
    end

    snapshots do
      before_deploy true
      keep 3
    end
  end
end
