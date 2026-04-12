defmodule Zed.IR.ValidateTest do
  use ExUnit.Case, async: true

  alias Zed.IR
  alias Zed.IR.{Node, Validate}

  describe "validation" do
    test "passes for valid IR" do
      ir = %IR{
        name: :test,
        pool: "tank",
        datasets: [%Node{id: "apps/web", type: :dataset, config: %{}}],
        apps: [
          %Node{
            id: :web,
            type: :app,
            config: %{dataset: "apps/web", cookie: {:env, "COOKIE"}}
          }
        ]
      }

      assert Validate.run!(ir) == ir
    end

    test "raises on missing pool" do
      ir = %IR{name: :test, pool: nil}

      assert_raise Zed.ValidationError, ~r/pool/, fn ->
        Validate.run!(ir)
      end
    end

    test "raises on broken dataset reference" do
      ir = %IR{
        name: :test,
        pool: "tank",
        datasets: [],
        apps: [
          %Node{
            id: :web,
            type: :app,
            config: %{dataset: "apps/nonexistent"}
          }
        ]
      }

      assert_raise Zed.ValidationError, ~r/nonexistent/, fn ->
        Validate.run!(ir)
      end
    end

    test "raises on broken jail contains reference" do
      ir = %IR{
        name: :test,
        pool: "tank",
        datasets: [],
        apps: [],
        jails: [
          %Node{
            id: :my_jail,
            type: :jail,
            config: %{contains: :ghost_app}
          }
        ]
      }

      assert_raise Zed.ValidationError, ~r/ghost_app/, fn ->
        Validate.run!(ir)
      end
    end

    test "raises on inline cookie string" do
      ir = %IR{
        name: :test,
        pool: "tank",
        datasets: [],
        apps: [
          %Node{
            id: :web,
            type: :app,
            config: %{cookie: "my_secret_cookie"}
          }
        ]
      }

      assert_raise Zed.ValidationError, ~r/inline cookie/, fn ->
        Validate.run!(ir)
      end
    end

    test "raises on inline cookie atom" do
      ir = %IR{
        name: :test,
        pool: "tank",
        datasets: [],
        apps: [
          %Node{
            id: :web,
            type: :app,
            config: %{cookie: :my_secret}
          }
        ]
      }

      assert_raise Zed.ValidationError, ~r/inline cookie/, fn ->
        Validate.run!(ir)
      end
    end

    test "allows {:env, var} cookie" do
      ir = %IR{
        name: :test,
        pool: "tank",
        datasets: [],
        apps: [
          %Node{
            id: :web,
            type: :app,
            config: %{cookie: {:env, "RELEASE_COOKIE"}}
          }
        ]
      }

      assert Validate.run!(ir) == ir
    end
  end
end
