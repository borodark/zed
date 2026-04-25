defmodule Zed.Platform.BastilleTest do
  @moduledoc """
  Pure-Elixir unit tests for `Zed.Platform.Bastille` using
  `Zed.Platform.Bastille.Runner.Mock`. No bastille binary required;
  runs on any host.

  Live integration tests live in `bastille_integration_test.exs`,
  tagged `:bastille_live`.
  """

  use ExUnit.Case, async: false
  # async: false because the Mock is a named singleton agent.

  alias Zed.Platform.Bastille
  alias Zed.Platform.Bastille.Runner.Mock

  setup do
    case Mock.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Mock.reset()
    end

    Application.put_env(:zed, Zed.Platform.Bastille, runner: Mock)

    on_exit(fn ->
      Application.delete_env(:zed, Zed.Platform.Bastille)
    end)

    :ok
  end

  describe "create/2" do
    test "dispatches with name + release + ip on success" do
      Mock.expect(:create, {"verify-sandbox: created\n", 0})
      assert :ok = Bastille.create("foo", ip: "10.17.89.50/24")

      assert [{:create, ["foo", "15.0-RELEASE", "10.17.89.50/24"], _}] = Mock.calls()
    end

    test "honours :release override" do
      Mock.expect(:create, {"", 0})
      assert :ok = Bastille.create("bar", ip: "10.17.89.51/24", release: "14.2-RELEASE")

      assert [{:create, ["bar", "14.2-RELEASE", "10.17.89.51/24"], _}] = Mock.calls()
    end

    test "fails fast on missing :ip" do
      assert {:error, {:missing_opt, :ip}} = Bastille.create("foo", release: "15.0-RELEASE")
      assert Mock.calls() == [], "runner should not be invoked"
    end

    test "rejects invalid name" do
      assert {:error, :invalid_name} = Bastille.create("bad name", ip: "10.0.0.1/24")
      assert Mock.calls() == []
    end

    test "surfaces non-zero exit as :bastille_exit" do
      Mock.expect(:create, {"[ERROR]: Jail already exists: foo", 1})
      assert {:error, {:bastille_exit, 1, "[ERROR]: Jail already exists: foo"}} =
               Bastille.create("foo", ip: "10.17.89.50/24")
    end
  end

  describe "start/1, stop/1" do
    test "start dispatches with just name" do
      Mock.expect(:start, {"", 0})
      assert :ok = Bastille.start("foo")
      assert [{:start, ["foo"], _}] = Mock.calls()
    end

    test "stop dispatches with just name" do
      Mock.expect(:stop, {"", 0})
      assert :ok = Bastille.stop("foo")
      assert [{:stop, ["foo"], _}] = Mock.calls()
    end

    test "both reject invalid names" do
      assert {:error, :invalid_name} = Bastille.start("with space")
      assert {:error, :invalid_name} = Bastille.stop("../../etc")
      assert Mock.calls() == []
    end
  end

  describe "destroy/2" do
    # destroy/2 invokes :destroy via the runner, then a follow-up
    # :list call to verify the post-condition (see "Bastille
    # exits 0 while leaving the jail in place" comment in
    # Bastille.destroy/2). The Mock expectation has to cover both.
    test "dispatches :destroy then verifies via :list" do
      Mock.expect(:destroy, {"foo: removed\n", 0})
      Mock.expect(:list, {"JID Name\n", 0})
      assert :ok = Bastille.destroy("foo")
      assert [{:destroy, ["foo"], _}, {:list, [], _}] = Mock.calls()
    end

    test "preserves opts to runner (so e.g. :force can flow through)" do
      Mock.expect(:destroy, {"", 0})
      Mock.expect(:list, {"JID Name\n", 0})
      Bastille.destroy("foo", force: true)
      assert [{:destroy, ["foo"], [force: true]}, {:list, [], _}] = Mock.calls()
    end

    test "surfaces error and skips post-condition check on non-zero exit" do
      Mock.expect(:destroy, {"jail busy", 2})
      assert {:error, {:bastille_exit, 2, "jail busy"}} = Bastille.destroy("foo")
      # No :list call because destroy already failed.
      assert [{:destroy, ["foo"], _}] = Mock.calls()
    end

    test "returns {:error, :destroy_did_nothing} when bastille exits 0 but jail still listed" do
      # Bastille 1.4 has been observed to exit 0 with a "Jail is
      # running. Use -a to auto-stop." message while leaving the
      # jail in place. The adapter's post-condition check catches
      # this regardless of bastille version.
      Mock.expect(:destroy, {"Jail is running.\nUse [-a|--auto] to auto-stop the jail.\n", 0})

      Mock.expect(:list, {
        " JID  Name  Boot  Prio  State  Type  IP Address  Published Ports  Release  Tags\n" <>
          "  3   foo   on    99    Up     thin  10.0.0.5    -                15.0-RELEASE  -\n",
        0
      })

      assert {:error, {:destroy_did_nothing, "foo"}} = Bastille.destroy("foo")
    end

    test "returns :ok when bastille exits 0 and follow-up list confirms gone" do
      Mock.expect(:destroy, {"foo: removed\n", 0})

      Mock.expect(:list, {
        " JID  Name  Boot  Prio  State  Type  IP Address  Published Ports  Release  Tags\n",
        0
      })

      assert :ok = Bastille.destroy("foo")
    end
  end

  describe "cmd/2" do
    test "dispatches name followed by argv" do
      Mock.expect(:cmd, {"FreeBSD\n", 0})
      assert {:ok, "FreeBSD\n"} = Bastille.cmd("foo", ["uname", "-s"])
      assert [{:cmd, ["foo", "uname", "-s"], _}] = Mock.calls()
    end

    test "wraps non-zero into error" do
      Mock.expect(:cmd, {"command not found: blarg", 127})
      assert {:error, {:bastille_exit, 127, "command not found: blarg"}} =
               Bastille.cmd("foo", ["blarg"])
    end
  end

  describe "exists?/1" do
    test "returns true when bastille list includes the name in column 2" do
      Mock.expect(:list, {
        " JID  Name     Boot  Prio  State    Type   IP Address  Published Ports  Release          Tags\n" <>
          "  3   ghost   on    0     Up       thin   10.0.0.5    -                15.0-RELEASE     -\n",
        0
      })

      assert Bastille.exists?("ghost")
    end

    test "returns false when bastille list does not include the name" do
      Mock.expect(:list, {
        " JID  Name     Boot  Prio  State    Type   IP Address  Published Ports  Release          Tags\n" <>
          "  3   other   on    0     Up       thin   10.0.0.5    -                15.0-RELEASE     -\n",
        0
      })

      refute Bastille.exists?("ghost")
    end

    test "returns false on empty list output" do
      Mock.expect(:list, {" JID  Name  Boot  Prio  State  Type  IP Address  Published Ports  Release  Tags\n", 0})
      refute Bastille.exists?("ghost")
    end

    test "returns false when bastille list itself errors" do
      Mock.expect(:list, {"bastille: error\n", 1})
      refute Bastille.exists?("ghost")
    end

    test "name-prefix is not enough — must be an exact column match" do
      # 'ghost-test' must not match 'ghost'.
      Mock.expect(:list, {
        " JID  Name         Boot  Prio  State  Type   IP Address  Published Ports  Release  Tags\n" <>
          "  3   ghost-test  on    0     Up     thin   10.0.0.5    -                15.0-RELEASE  -\n",
        0
      })

      refute Bastille.exists?("ghost")
    end

    test "rejects invalid names without invoking the runner" do
      refute Bastille.exists?("../etc/passwd")
      assert Mock.calls() == []
    end
  end

  describe "name validation" do
    test "accepts alphanumerics, underscore, dash" do
      Mock.expect(:start, {"", 0})
      assert :ok = Bastille.start("zed-test_42")
    end

    test "rejects dots" do
      # Bastille treats `.` specially in some subcommands; we disallow.
      assert {:error, :invalid_name} = Bastille.start("foo.bar")
    end

    test "rejects empty string" do
      assert {:error, :invalid_name} = Bastille.start("")
    end

    test "rejects shell metacharacters" do
      for bad <- ["foo;rm -rf /", "foo|cat", "$foo", "`whoami`", "foo bar"] do
        assert {:error, :invalid_name} = Bastille.start(bad)
      end
    end
  end
end
