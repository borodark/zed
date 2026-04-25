defmodule Zed.Ops.SocketIntegrationTest do
  @moduledoc """
  End-to-end socket round-trip: server up, pool up, ping/pong with
  peer-cred check on the dev account. Reject path is exercised by
  starting a server with an empty `allowed_uids` set — the connection
  attempt should be closed before any request lands.
  """

  use ExUnit.Case, async: false

  alias Zed.Ops.{Socket, Wire}
  alias Zed.Web.OpsClient

  defp tmp_socket_path do
    "/tmp/zed-ops-it-#{System.unique_integer([:positive])}.sock"
  end

  defp current_uid do
    {out, 0} = System.cmd("id", ["-u"])
    String.trim(out) |> String.to_integer()
  end

  describe "ping → pong" do
    test "round-trips a request through the pool to the listener" do
      path = tmp_socket_path()
      uid = current_uid()

      start_supervised!({Socket, path: path, allowed_uids: [uid], name: :"ops_socket_#{uid}"})

      # Wait briefly for the listener to bind.
      assert wait_for(fn -> File.exists?(path) end, 2_000)

      start_supervised!({OpsClient.Pool, path: path, size: 2})

      reply = OpsClient.call("req-1", :ping, %{}, timeout: 2_000)
      assert {:zedops_reply, "req-1", :pong} = reply

      File.rm(path)
    end

    test "unknown action returns a structured error" do
      path = tmp_socket_path()
      uid = current_uid()

      start_supervised!({Socket, path: path, allowed_uids: [uid], name: :"ops_socket_uk_#{uid}"})
      assert wait_for(fn -> File.exists?(path) end, 2_000)
      start_supervised!({OpsClient.Pool, path: path, size: 1})

      reply = OpsClient.call("req-2", :elephant, %{})
      assert {:zedops_reply, "req-2", {:error, {:unknown_action, :elephant}}} = reply

      File.rm(path)
    end
  end

  describe "peer-cred reject" do
    test "an empty allowed_uids set drops the connection without a reply" do
      path = tmp_socket_path()

      start_supervised!({Socket, path: path, allowed_uids: [], name: :"ops_socket_rj_#{System.unique_integer([:positive])}"})
      assert wait_for(fn -> File.exists?(path) end, 2_000)

      # Connect raw (not via the pool, so we can observe the close).
      {:ok, sock} =
        :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
          :binary,
          {:packet, 4},
          {:active, false}
        ])

      {:ok, frame} =
        Wire.encode({:zedops, :v1, "rej-1", :ping, %{}, <<>>})

      _ = :gen_tcp.send(sock, frame)

      # Server-side handler closes the socket after the cred check.
      # `recv` returns :closed once the close propagates — generously
      # bounded so a slow scheduler doesn't flake.
      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
      :gen_tcp.close(sock)

      File.rm(path)
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
