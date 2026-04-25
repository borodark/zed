defmodule Zed.Ops.Socket do
  @moduledoc """
  Unix-domain socket listener for the zedops process (A5a.2).

  Accepts connections, calls `Zed.Ops.PeerCred.read/1` on the freshly
  accepted FD, and rejects any peer whose uid is not in the allowed
  set. Surviving connections enter a request loop: read a frame,
  decode it via `Zed.Ops.Wire`, dispatch to the action handler, write
  the reply.

  Configuration
  -------------

    * `:path` — filesystem path of the listening socket (default
      `/var/run/zed/ops.sock`).
    * `:allowed_uids` — list of integer uids permitted to connect.
      Defaults to `[Zed.Ops.Socket.current_uid()]` so dev/test on a
      single account just works; production sets this to `[zedweb_uid]`
      explicitly.
    * `:handler` — `{module, function}` invoked with the decoded
      request, returning the reply term. Default is the built-in
      `ping` handler — A5a.4 swaps it for the bastille dispatcher.
    * `:mode` — file mode applied to the socket after `bind`. Default
      `0o660`.

  The accept loop runs in a dedicated process; one Task per accepted
  connection handles the request loop. Connection-bounded; a slow peer
  cannot starve other peers.
  """

  use GenServer
  require Logger

  alias Zed.Ops.{PeerCred, Wire}

  @default_path "/var/run/zed/ops.sock"
  @accept_timeout 1_000
  @recv_timeout 30_000

  # Public API ---------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the OS uid of the current process."
  def current_uid do
    {out, 0} = System.cmd("id", ["-u"])
    String.trim(out) |> String.to_integer()
  end

  @doc "Default ping handler: returns `:pong` for any `:ping` action."
  def default_handler({:zedops, :v1, request_id, :ping, _payload, _sig}) do
    {:zedops_reply, request_id, :pong}
  end

  def default_handler({:zedops, :v1, request_id, action, _payload, _sig}) do
    {:zedops_reply, request_id, {:error, {:unknown_action, action}}}
  end

  def default_handler(other) do
    {:zedops_reply, "unknown", {:error, {:bad_request, other}}}
  end

  # GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path)
    allowed = Keyword.get(opts, :allowed_uids, [current_uid()])
    handler = Keyword.get(opts, :handler, {__MODULE__, :default_handler})
    mode = Keyword.get(opts, :mode, 0o660)

    File.mkdir_p!(Path.dirname(path))
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:ifaddr, {:local, String.to_charlist(path)}},
        {:packet, 4},
        {:active, false},
        {:reuseaddr, true}
      ])

    File.chmod!(path, mode)

    state = %{
      listen: listen,
      path: path,
      allowed_uids: MapSet.new(allowed),
      handler: handler
    }

    send(self(), :accept)
    {:ok, state}
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen, @accept_timeout) do
      {:ok, conn} ->
        spawn_handler(conn, state)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error("zedops accept failed: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def terminate(_reason, %{path: path}) do
    _ = File.rm(path)
    :ok
  end

  # Connection handling ------------------------------------------------

  defp spawn_handler(conn, state) do
    {:ok, child} =
      Task.Supervisor.start_child(zed_ops_task_sup(), fn -> handle_conn(conn, state) end)

    :ok = :gen_tcp.controlling_process(conn, child)
  end

  defp zed_ops_task_sup do
    case Process.whereis(Zed.Ops.TaskSupervisor) do
      nil ->
        {:ok, _} = Task.Supervisor.start_link(name: Zed.Ops.TaskSupervisor)
        Zed.Ops.TaskSupervisor

      pid when is_pid(pid) ->
        Zed.Ops.TaskSupervisor
    end
  end

  defp handle_conn(conn, state) do
    case :inet.getfd(conn) do
      {:ok, fd} ->
        case PeerCred.read(fd) do
          {:ok, %{uid: uid}} ->
            if MapSet.member?(state.allowed_uids, uid) do
              loop(conn, state, uid)
            else
              Logger.warning(
                "zedops: rejected peer uid=#{uid} (allowed=#{inspect(MapSet.to_list(state.allowed_uids))})"
              )

              :gen_tcp.close(conn)
            end

          {:error, reason} ->
            Logger.error("zedops: peer cred lookup failed: #{inspect(reason)}")
            :gen_tcp.close(conn)
        end

      {:error, reason} ->
        Logger.error("zedops: getfd failed: #{inspect(reason)}")
        :gen_tcp.close(conn)
    end
  end

  defp loop(conn, state, peer_uid) do
    case :gen_tcp.recv(conn, 0, @recv_timeout) do
      {:ok, frame} ->
        reply =
          case Wire.decode(frame) do
            {:ok, request} ->
              {mod, fun} = state.handler
              apply(mod, fun, [request])

            {:error, reason} ->
              {:zedops_reply, "unknown", {:error, reason}}
          end

        case Wire.encode(reply) do
          {:ok, encoded} ->
            case :gen_tcp.send(conn, encoded) do
              :ok -> loop(conn, state, peer_uid)
              {:error, _} -> :gen_tcp.close(conn)
            end

          {:error, reason} ->
            Logger.error("zedops: reply too large: #{inspect(reason)}")
            :gen_tcp.close(conn)
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("zedops: recv failed: #{inspect(reason)}")
        :gen_tcp.close(conn)
    end
  end
end
