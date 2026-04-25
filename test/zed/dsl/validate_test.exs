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

  describe "secret references (A0)" do
    defp ir_with_cookie(cookie) do
      %IR{
        name: :test,
        pool: "tank",
        datasets: [],
        apps: [
          %Node{id: :web, type: :app, config: %{cookie: cookie}}
        ]
      }
    end

    test "accepts {:secret, slot} shorthand with default field :value" do
      ir = ir_with_cookie({:secret, :beam_cookie})
      assert Validate.run!(ir) == ir
    end

    test "accepts {:secret, slot, field} when field is valid" do
      ir = ir_with_cookie({:secret, :ssh_host_ed25519, :priv})
      assert Validate.run!(ir) == ir
    end

    test "accepts {:secret, slot, field, storage: :local_file}" do
      ir = ir_with_cookie({:secret, :beam_cookie, :value, storage: :local_file})
      assert Validate.run!(ir) == ir
    end

    test "accepts {:secret, slot, field, []} — empty opts defaults to :local_file" do
      ir = ir_with_cookie({:secret, :beam_cookie, :value, []})
      assert Validate.run!(ir) == ir
    end

    test "rejects unknown slot with list of known slots in message" do
      ir = ir_with_cookie({:secret, :ghost_slot})

      assert_raise Zed.ValidationError, ~r/unknown secret slot :ghost_slot/, fn ->
        Validate.run!(ir)
      end

      assert_raise Zed.ValidationError, ~r/beam_cookie/, fn ->
        Validate.run!(ir)
      end
    end

    test "rejects invalid field for a known slot" do
      ir = ir_with_cookie({:secret, :beam_cookie, :ghost_field})

      assert_raise Zed.ValidationError,
                   ~r/slot :beam_cookie has no field :ghost_field/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects keypair slot accessed as :value" do
      ir = ir_with_cookie({:secret, :ssh_host_ed25519, :value})

      assert_raise Zed.ValidationError,
                   ~r/no field :value/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects pending storage mode :probnik_vault with Layer D6 pointer" do
      ir = ir_with_cookie({:secret, :beam_cookie, :value, storage: :probnik_vault})

      assert_raise Zed.ValidationError,
                   ~r/probnik_vault is not yet implemented, pending Layer D6/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects pending storage mode :probnik_vault_pair with Layer D6 pointer" do
      ir = ir_with_cookie({:secret, :beam_cookie, :value, storage: :probnik_vault_pair})

      assert_raise Zed.ValidationError,
                   ~r/probnik_vault_pair is not yet implemented, pending Layer D6/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects pending storage mode :shamir_k_of_n with Layer D7 pointer" do
      ir = ir_with_cookie({:secret, :beam_cookie, :value, storage: :shamir_k_of_n})

      assert_raise Zed.ValidationError,
                   ~r/shamir_k_of_n is not yet implemented, pending Layer D7/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects entirely unknown storage mode" do
      ir = ir_with_cookie({:secret, :beam_cookie, :value, storage: :smoke_signals})

      assert_raise Zed.ValidationError,
                   ~r/unknown storage mode :smoke_signals/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects non-atom slot name" do
      ir = ir_with_cookie({:secret, "beam_cookie"})

      assert_raise Zed.ValidationError,
                   ~r/secret slot must be an atom/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects non-atom field name" do
      ir = ir_with_cookie({:secret, :beam_cookie, "value"})

      assert_raise Zed.ValidationError,
                   ~r/secret field must be an atom/,
                   fn -> Validate.run!(ir) end
    end
  end

  describe "cluster validation (S2)" do
    defp ir_with_cluster(cluster_config) do
      %Zed.IR{
        name: :test,
        pool: "tank",
        datasets: [],
        apps: [],
        jails: [],
        zones: [],
        clusters: [
          %Zed.IR.Node{id: :demo, type: :cluster, config: cluster_config, deps: []}
        ],
        snapshot_config: %{}
      }
    end

    test "rejects inline cookie string on a cluster" do
      ir = ir_with_cluster(%{cookie: "literal-cookie", members: []})

      assert_raise Zed.ValidationError,
                   ~r/cluster :demo has an inline cookie string/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects inline cookie atom on a cluster" do
      ir = ir_with_cluster(%{cookie: :literal_cookie, members: []})

      assert_raise Zed.ValidationError,
                   ~r/cluster :demo has an inline cookie atom/,
                   fn -> Validate.run!(ir) end
    end

    test "accepts {:env, var} cluster cookie" do
      ir = ir_with_cluster(%{cookie: {:env, "COOKIE"}, members: []})
      assert %Zed.IR{} = Validate.run!(ir)
    end

    test "accepts {:secret, slot, field} cluster cookie referencing a known slot" do
      ir = ir_with_cluster(%{cookie: {:secret, :beam_cookie, :value}, members: []})
      assert %Zed.IR{} = Validate.run!(ir)
    end

    test "rejects unknown slot on cluster cookie" do
      ir = ir_with_cluster(%{cookie: {:secret, :ghost_cluster_cookie, :value}, members: []})

      assert_raise Zed.ValidationError,
                   ~r/unknown secret slot :ghost_cluster_cookie/,
                   fn -> Validate.run!(ir) end
    end

    test "accepts well-shaped node atoms" do
      ir =
        ir_with_cluster(%{
          cookie: {:env, "C"},
          members: [:"web@10.0.0.1", :"worker@host2"]
        })

      assert %Zed.IR{} = Validate.run!(ir)
    end

    test "rejects member without @ separator" do
      ir = ir_with_cluster(%{cookie: {:env, "C"}, members: [:web]})

      assert_raise Zed.ValidationError,
                   ~r/member :web is not a valid node atom/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects non-atom member" do
      ir = ir_with_cluster(%{cookie: {:env, "C"}, members: ["web@host"]})

      assert_raise Zed.ValidationError,
                   ~r/member "web@host" is not a valid node atom/,
                   fn -> Validate.run!(ir) end
    end

    test "rejects non-list :members" do
      ir = ir_with_cluster(%{cookie: {:env, "C"}, members: :not_a_list})

      assert_raise Zed.ValidationError,
                   ~r/cluster :demo :members must be a list/,
                   fn -> Validate.run!(ir) end
    end

    test "missing :members defaults to empty list (cluster declared but unpopulated)" do
      ir = ir_with_cluster(%{cookie: {:env, "C"}})
      assert %Zed.IR{} = Validate.run!(ir)
    end
  end
end
