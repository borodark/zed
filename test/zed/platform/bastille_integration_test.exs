defmodule Zed.Platform.BastilleIntegrationTest do
  @moduledoc """
  End-to-end test against a real `bastille` binary. Tagged
  `:bastille_live`; excluded from default runs.

  ## Running

      # On a host that passed scripts/verify-bastille-host.sh --smoke:
      mix test --only bastille_live test/zed/platform/bastille_integration_test.exs

  Each test gets a unique jail name `zed-test-<unique-int>` so
  parallel test files / re-runs don't collide on the verify-sandbox
  IP space (`10.17.89.0/24`).

  Cleanup is in `on_exit`; if a test crashes, the next run still
  starts clean because the destroy path tolerates "not found".
  """

  use ExUnit.Case, async: false
  @moduletag :bastille_live

  alias Zed.Platform.Bastille

  @cidr_pool "10.17.89."

  setup_all do
    # Bastille refuses to run as a non-root user; test runner is
    # typically the io user with a wheel-doas rule that allows
    # `cmd bastille` without password. See doas.conf:
    #   permit nopass :wheel as root cmd bastille
    prev = Application.get_env(:zed, Zed.Platform.Bastille, [])

    Application.put_env(
      :zed,
      Zed.Platform.Bastille,
      Keyword.put(prev, :privilege_prefix, System.get_env("ZED_BASTILLE_SUDO", "doas"))
    )

    on_exit(fn -> Application.put_env(:zed, Zed.Platform.Bastille, prev) end)

    :ok
  end

  setup do
    # 32 bits of entropy in the name. unique_integer/1 + os_time
    # had collision modes when two test runs landed in the same
    # second AND the per-VM counter reset to overlapping values
    # AND a prior run didn't clean up. Random bytes sidestep all
    # three.
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    name = "zed-test-#{suffix}"
    # Octet 100..199 carved out for adapter tests; verify-sandbox uses 249.
    octet = 100 + rem(System.unique_integer([:positive]), 100)
    ip = "#{@cidr_pool}#{octet}/24"

    # Defensive: if a stale jail with this name exists (clock skew or
    # a prior aborted run), wipe it so the test starts clean.
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

  test "create + start + cmd + stop + destroy round-trip", %{name: name, ip: ip} do
    assert :ok = Bastille.create(name, ip: ip)
    assert Bastille.exists?(name), "directory should exist after create"

    assert :ok = Bastille.start(name)

    assert {:ok, output} = Bastille.cmd(name, ["uname", "-s"])
    assert output =~ "FreeBSD"

    assert :ok = Bastille.stop(name)
    assert :ok = Bastille.destroy(name)
    refute Bastille.exists?(name), "directory should be gone after destroy"
  end

  test "create with invalid release surfaces error", %{name: name, ip: ip} do
    assert {:error, {:bastille_exit, _code, output}} =
             Bastille.create(name, ip: ip, release: "1.2.3-NOPE")

    # Bastille's error for an unbootstrapped release mentions either
    # "not found", "release", or "bootstrap" depending on version.
    assert output =~ ~r/(release|bootstrap|not found)/i
  end

  test "cmd against non-existent jail surfaces error" do
    name = "zed-test-nonexistent-#{System.unique_integer([:positive])}"
    assert {:error, {:bastille_exit, _, _}} = Bastille.cmd(name, ["uname", "-a"])
  end

  test "destroy of non-existent is non-fatal (used in setup cleanup)" do
    name = "zed-test-ghost-#{System.unique_integer([:positive])}"
    # Some bastille versions exit 0 with "no such jail" message; others
    # exit 1. Either way the adapter returns either :ok or an
    # {:error, ...} we tolerate. Importantly: it should not raise.
    result = Bastille.destroy(name)
    assert result == :ok or match?({:error, _}, result)
  end

  test "exists? mirrors bastille create/destroy state", %{name: name, ip: ip} do
    refute Bastille.exists?(name)
    assert :ok = Bastille.create(name, ip: ip)
    assert Bastille.exists?(name)
    assert :ok = Bastille.destroy(name)
    refute Bastille.exists?(name)
  end
end
