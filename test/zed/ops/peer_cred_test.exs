defmodule Zed.Ops.PeerCredTest do
  use ExUnit.Case, async: true

  alias Zed.Ops.PeerCred

  describe "read/1 over a connected Unix socket" do
    test "returns the calling process's uid/gid" do
      path = "/tmp/zed-pc-test-#{System.unique_integer([:positive])}.sock"

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          {:ifaddr, {:local, String.to_charlist(path)}},
          {:packet, 4},
          {:active, false}
        ])

      task =
        Task.async(fn ->
          {:ok, conn} = :gen_tcp.accept(listen, 5_000)
          {:ok, fd} = :inet.getfd(conn)
          result = PeerCred.read(fd)
          :gen_tcp.close(conn)
          result
        end)

      {:ok, client} =
        :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
          :binary,
          {:packet, 4},
          {:active, false}
        ])

      result = Task.await(task, 5_000)
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
      File.rm(path)

      {expected_uid, _} = System.cmd("id", ["-u"])
      expected_uid = String.trim(expected_uid) |> String.to_integer()

      assert {:ok, %{uid: uid, gid: _gid}} = result
      assert uid == expected_uid
    end

    test "returns :error on a non-socket fd" do
      # stdout is a tty/pipe, not a socket — getpeereid/getsockopt fails.
      assert {:error, _} = PeerCred.read(1)
    end
  end
end
