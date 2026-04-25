defmodule Zed.RoleTest do
  use ExUnit.Case, async: false

  alias Zed.Role

  setup do
    # Snapshot env + app config so each test starts clean. Role is
    # read via `current/0` and the A5a.7 guard reads RELEASE_NAME, so
    # all three vectors need restoring.
    prior_role = System.get_env("ZED_ROLE")
    prior_release = System.get_env("RELEASE_NAME")
    prior_cfg = Application.get_env(:zed, :role)

    on_exit(fn ->
      case prior_role do
        nil -> System.delete_env("ZED_ROLE")
        v -> System.put_env("ZED_ROLE", v)
      end

      case prior_release do
        nil -> System.delete_env("RELEASE_NAME")
        v -> System.put_env("RELEASE_NAME", v)
      end

      case prior_cfg do
        nil -> Application.delete_env(:zed, :role)
        v -> Application.put_env(:zed, :role, v)
      end
    end)

    System.delete_env("ZED_ROLE")
    System.delete_env("RELEASE_NAME")
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

  describe "assert_release_role!/0 (A5a.7)" do
    test "no RELEASE_NAME → :ok regardless of role" do
      assert :ok = Role.assert_release_role!()
      Application.put_env(:zed, :role, :web)
      assert :ok = Role.assert_release_role!()
      Application.put_env(:zed, :role, :ops)
      assert :ok = Role.assert_release_role!()
    end

    test "zedweb release with role=:web → :ok" do
      System.put_env("RELEASE_NAME", "zedweb")
      Application.put_env(:zed, :role, :web)
      assert :ok = Role.assert_release_role!()
    end

    test "zedops release with role=:ops → :ok" do
      System.put_env("RELEASE_NAME", "zedops")
      Application.put_env(:zed, :role, :ops)
      assert :ok = Role.assert_release_role!()
    end

    test "zedweb release with role=:full raises" do
      System.put_env("RELEASE_NAME", "zedweb")
      Application.put_env(:zed, :role, :full)

      assert_raise RuntimeError, ~r/zedweb.*ZED_ROLE=web/s, fn ->
        Role.assert_release_role!()
      end
    end

    test "zedweb release with role=:ops raises" do
      System.put_env("RELEASE_NAME", "zedweb")
      Application.put_env(:zed, :role, :ops)

      assert_raise RuntimeError, ~r/zedweb.*ZED_ROLE=web/s, fn ->
        Role.assert_release_role!()
      end
    end

    test "zedops release with role=:full raises" do
      System.put_env("RELEASE_NAME", "zedops")
      Application.put_env(:zed, :role, :full)

      assert_raise RuntimeError, ~r/zedops.*ZED_ROLE=ops/s, fn ->
        Role.assert_release_role!()
      end
    end

    test "unrelated release name with any role → :ok" do
      System.put_env("RELEASE_NAME", "some_other_release")
      Application.put_env(:zed, :role, :full)
      assert :ok = Role.assert_release_role!()
    end
  end
end
