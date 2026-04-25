defmodule Zed.Ops.BastilleHandlerLiveTest do
  @moduledoc """
  A5a.5 acceptance test — the full privilege-boundary path against a
  real `bastille` binary on FreeBSD.

  Exercises:

      Zed.Platform.Bastille
        → Runner.OpsClient                  (web side)
          → OpsClient.call (Unix socket)
            → Zed.Ops.Socket                (peer-cred on accept)
              → Zed.Ops.Bastille.Handler
                → Runner.System             (real `doas bastille ...`)

  Tagged `:bastille_live`; excluded from default runs. Requires the
  same host setup as `bastille_integration_test.exs` plus the A5a.3
  `scripts/host-bring-up.sh` having created `/var/run/zed/` for the
  socket.

  ## Privilege

  The user that runs `mix test --only bastille_live` must hold the
  doas rules in `docs/doas.conf.zedops`. In practice that is either
  `zedops` (production) or a wheel member who ran `doas -v` recently
  (Mac dev, relaxed bring-up posture). The test does NOT touch any
  runner config — the boundary is the production path, no overrides.
  """

  use ExUnit.Case, async: false
  @moduletag :bastille_live

  alias Zed.Platform.Bastille

  @cidr_pool "10.17.89."

  defp tmp_socket_path do
    "/tmp/zed-bh-live-#{System.unique_integer([:positive])}.sock"
  end

  defp current_uid do
    {out, 0} = System.cmd("id", ["-u"])
    String.trim(out) |> String.to_integer()
  end

  setup do
    path = tmp_socket_path()
    uid = current_uid()

    # Web side dispatches via OpsClient; ops-side handler uses the
    # real System runner (no override means default = Runner.System).
    Application.put_env(:zed, Zed.Platform.Bastille, runner: Zed.Platform.Bastille.Runner.OpsClient)

    on_exit(fn ->
      Application.delete_env(:zed, Zed.Platform.Bastille)
      File.rm(path)
    end)

    start_supervised!(
      {Zed.Ops.Socket,
       path: path,
       allowed_uids: [uid],
       handler: {Zed.Ops.Bastille.Handler, :handle},
       name: :"bh_live_socket_#{System.unique_integer([:positive])}"}
    )

    # Wait briefly for the socket to bind.
    deadline = System.monotonic_time(:millisecond) + 2_000

    fun = fn ->
      File.exists?(path) || System.monotonic_time(:millisecond) >= deadline
    end

    Stream.iterate(0, &(&1 + 1))
    |> Enum.take_while(fn _ -> not fun.() end)
    |> Enum.each(fn _ -> Process.sleep(20) end)

    start_supervised!({Zed.Web.OpsClient.Pool, path: path, size: 2})

    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    name = "zed-test-bh-#{suffix}"
    octet = 100 + rem(System.unique_integer([:positive]), 100)
    ip = "#{@cidr_pool}#{octet}/24"

    if Bastille.exists?(name) do
      _ = Bastille.stop(name)
      _ = Bastille.destroy(name)
    end

    on_exit(fn ->
      _ = Bastille.stop(name)
      _ = Bastille.destroy(name)
    end)

    {:ok, name: name, ip: ip}
  end

  test "create + start + cmd + stop + destroy through the boundary",
       %{name: name, ip: ip} do
    assert :ok = Bastille.create(name, ip: ip)
    assert Bastille.exists?(name)

    assert :ok = Bastille.start(name)
    assert {:ok, output} = Bastille.cmd(name, ["uname", "-s"])
    assert output =~ "FreeBSD"

    assert :ok = Bastille.stop(name)
    assert :ok = Bastille.destroy(name)
    refute Bastille.exists?(name)
  end

  test "destroy of non-existent jail is non-fatal across the boundary" do
    name = "zed-test-bh-ghost-#{System.unique_integer([:positive])}"
    result = Bastille.destroy(name)
    assert result == :ok or match?({:error, _}, result)
  end
end
