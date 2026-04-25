defmodule Zed.Ops.BastilleHandlerIntegrationTest do
  @moduledoc """
  End-to-end test for the A5a.4 wiring:

      Zed.Platform.Bastille
        → Runner.OpsClient        (web side)
          → Zed.Web.OpsClient.call (Unix socket)
            → Zed.Ops.Socket       (peer-cred, frame, dispatch)
              → Zed.Ops.Bastille.Handler.handle/1
                → Runner.Mock      (ops side; would be Runner.System in prod)

  This proves the full round-trip without actually running `bastille`.
  The Mock receives the call with original argv + opts intact, so a
  hostile reframe of the request would surface as a missing or
  garbled call entry.
  """

  use ExUnit.Case, async: false

  alias Zed.Platform.Bastille
  alias Zed.Platform.Bastille.Runner

  setup do
    # Fresh mock instance for ops-side bastille handler.
    {:ok, _mock_pid} = Runner.Mock.start_link()
    Runner.Mock.reset()

    path = "/tmp/zed-bh-it-#{System.unique_integer([:positive])}.sock"
    {uid_str, 0} = System.cmd("id", ["-u"])
    uid = String.trim(uid_str) |> String.to_integer()

    # Install the mock as the runner the handler calls; install
    # OpsClient as the runner Bastille uses on the web side.
    Application.put_env(:zed, Zed.Ops.Bastille.Handler, runner: Runner.Mock)
    Application.put_env(:zed, Zed.Platform.Bastille, runner: Runner.OpsClient)

    on_exit(fn ->
      Application.delete_env(:zed, Zed.Ops.Bastille.Handler)
      Application.delete_env(:zed, Zed.Platform.Bastille)
      File.rm(path)
    end)

    start_supervised!(
      {Zed.Ops.Socket,
       path: path,
       allowed_uids: [uid],
       handler: {Zed.Ops.Bastille.Handler, :handle},
       name: :"bh_socket_#{System.unique_integer([:positive])}"}
    )

    assert wait_for(fn -> File.exists?(path) end, 2_000)

    start_supervised!({Zed.Web.OpsClient.Pool, path: path, size: 2})

    %{path: path, uid: uid}
  end

  describe "bastille create round-trips through the boundary" do
    test "Bastille.create/2 reaches Runner.Mock with original argv" do
      Runner.Mock.expect(:create, {"created jail: foo\n", 0})

      assert :ok = Bastille.create("foo", ip: "10.0.0.5/24", release: "15.0-RELEASE")

      calls = Runner.Mock.calls()
      assert [{:create, ["foo", "15.0-RELEASE", "10.0.0.5/24"], _opts}] = calls
    end

    test "non-zero exit propagates back through the wire" do
      Runner.Mock.expect(:create, {"create failed: dataset busy\n", 2})

      assert {:error, {:bastille_exit, 2, "create failed: dataset busy"}} =
               Bastille.create("foo", ip: "10.0.0.5/24")
    end
  end

  describe "list / exists? round-trip" do
    test "exists? sees the jail name in the mocked list output" do
      Runner.Mock.expect(:list, {"  JID  NAME  STATE\n  1    foo   Up\n", 0})

      assert Bastille.exists?("foo")

      assert [{:list, [], []}] = Runner.Mock.calls()
    end

    test "exists? returns false when the name isn't listed" do
      Runner.Mock.expect(:list, {"  JID  NAME  STATE\n", 0})

      refute Bastille.exists?("foo")
    end
  end

  describe "destroy verifies the post-condition through the wire" do
    test "post-destroy exists? = false → :ok" do
      # The mock returns success for destroy AND returns an empty
      # list, so exists?/1 returns false → Bastille.destroy returns :ok.
      Runner.Mock.expect(:destroy, {"destroyed\n", 0})
      Runner.Mock.expect(:list, {"  JID  NAME  STATE\n", 0})

      assert :ok = Bastille.destroy("foo")

      # Two ops crossed the boundary: destroy + list (post-condition).
      verbs = Runner.Mock.calls() |> Enum.map(fn {v, _, _} -> v end)
      assert verbs == [:destroy, :list]
    end

    test "post-destroy exists? = true → {:error, :destroy_did_nothing}" do
      Runner.Mock.expect(:destroy, {"silent no-op (jail still running)\n", 0})
      Runner.Mock.expect(:list, {"  JID  NAME  STATE\n  1    foo   Up\n", 0})

      assert {:error, {:destroy_did_nothing, "foo"}} = Bastille.destroy("foo")
    end
  end

  defp wait_for(fun, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(20); do_wait(fun, deadline)
    end
  end
end
