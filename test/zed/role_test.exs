defmodule Zed.RoleTest do
  use ExUnit.Case, async: false

  alias Zed.Role

  setup do
    # Snapshot env + app config so each test starts clean. Role is read
    # via `current/0` (env-first, app-config-fallback), so both vectors
    # need restoring.
    prior_env = System.get_env("ZED_ROLE")
    prior_cfg = Application.get_env(:zed, :role)

    on_exit(fn ->
      case prior_env do
        nil -> System.delete_env("ZED_ROLE")
        v -> System.put_env("ZED_ROLE", v)
      end

      case prior_cfg do
        nil -> Application.delete_env(:zed, :role)
        v -> Application.put_env(:zed, :role, v)
      end
    end)

    System.delete_env("ZED_ROLE")
    Application.delete_env(:zed, :role)
    :ok
  end

  describe "current/0" do
    test "defaults to :full when nothing is set" do
      assert Role.current() == :full
    end

    test "ZED_ROLE=web wins over app config" do
      Application.put_env(:zed, :role, :ops)
      System.put_env("ZED_ROLE", "web")
      assert Role.current() == :web
    end

    test "ZED_ROLE=ops" do
      System.put_env("ZED_ROLE", "ops")
      assert Role.current() == :ops
    end

    test "ZED_ROLE=full" do
      System.put_env("ZED_ROLE", "full")
      assert Role.current() == :full
    end

    test "app config :role used when env unset" do
      Application.put_env(:zed, :role, :ops)
      assert Role.current() == :ops
    end

    test "ZED_ROLE=garbage raises" do
      System.put_env("ZED_ROLE", "elephant")
      assert_raise ArgumentError, ~r/elephant/, fn -> Role.current() end
    end

    test "app config :role = :elephant raises" do
      Application.put_env(:zed, :role, :elephant)
      assert_raise ArgumentError, ~r/elephant/, fn -> Role.current() end
    end
  end
end
