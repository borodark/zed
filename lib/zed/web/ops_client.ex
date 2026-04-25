defmodule Zed.Web.OpsClient do
  @moduledoc """
  Client pool for the zedweb → zedops Unix socket (A5a.2).

  Holds a fixed-size pool of persistent worker GenServers, each owning
  one connection. Public `call/4` round-robins across workers via an
  `:atomics` counter. Workers reconnect on demand if the connection
  drops, surfacing the next request as the reconnect attempt — a
  transient socket failure costs one extra round-trip, not a crash.

  Pool size defaults to 4 workers, configurable via the
  `Zed.Web.OpsClient.Pool` start arg `:size`. Four covers light
  LiveView load with no contention; tune up if dashboards grow.

  Wire envelope is `{:zedops, :v1, request_id, action, payload,
  signature}` per `Zed.Ops.Wire`. The signature field is reserved for
  the A5c step-up token; today it is `<<>>` for non-destructive
  actions.
  """

  use GenServer
  require Logger

  alias Zed.Ops.Wire

  @default_path "/var/run/zed/ops.sock"
  @default_timeout 5_000

  # Pool API -----------------------------------------------------------

  defmodule Pool do
    @moduledoc "Supervisor for the OpsClient worker pool."
    use Supervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(opts) do
      size = Keyword.get(opts, :size, 4)
      path = Keyword.get(opts, :path, "/var/run/zed/ops.sock")

      counter = :atomics.new(1, [])
      :persistent_term.put({Zed.Web.OpsClient, :pool}, %{size: size, counter: counter})

      children =
        for i <- 1..size do
          %{
            id: {Zed.Web.OpsClient, i},
            start: {Zed.Web.OpsClient, :start_link, [[index: i, path: path]]}
          }
        end

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  @doc """
  Send a request through the pool. Returns the reply tuple
  `{:zedops_reply, request_id, result}` or `{:error, reason}` on
  transport failure.

  `request_id` should be a short binary; the caller is responsible for
  making it unique within the timeout window.
  """
  @spec call(binary, atom, term, keyword) :: term | {:error, term}
  def call(request_id, action, payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    signature = Keyword.get(opts, :signature, <<>>)

    case worker() do
      {:ok, pid} ->
        GenServer.call(pid, {:request, request_id, action, payload, signature}, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp worker do
    case :persistent_term.get({Zed.Web.OpsClient, :pool}, nil) do
      %{size: size, counter: counter} ->
        idx = rem(:atomics.add_get(counter, 1, 1) - 1, size) + 1
        case Process.whereis(name(idx)) do
          nil -> {:error, :pool_not_started}
          pid -> {:ok, pid}
        end

      nil ->
        {:error, :pool_not_started}
    end
  end

  defp name(idx), do: Module.concat([__MODULE__, "Worker", Integer.to_string(idx)])

  # GenServer worker ---------------------------------------------------

  def start_link(opts) do
    idx = Keyword.fetch!(opts, :index)
    GenServer.start_link(__MODULE__, opts, name: name(idx))
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path)
    {:ok, %{path: path, conn: nil}}
  end

  @impl true
  def handle_call({:request, request_id, action, payload, signature}, _from, state) do
    case ensure_conn(state) do
      {:ok, conn} ->
        request = {:zedops, :v1, request_id, action, payload, signature}

        with {:ok, encoded} <- Wire.encode(request),
             :ok <- :gen_tcp.send(conn, encoded),
             {:ok, frame} <- :gen_tcp.recv(conn, 0, @default_timeout),
             {:ok, decoded} <- Wire.decode(frame) do
          {:reply, decoded, %{state | conn: conn}}
        else
          {:error, reason} ->
            _ = :gen_tcp.close(conn)
            {:reply, {:error, reason}, %{state | conn: nil}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | conn: nil}}
    end
  end

  defp ensure_conn(%{conn: nil, path: path}) do
    :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
      :binary,
      {:packet, 4},
      {:active, false}
    ])
  end

  defp ensure_conn(%{conn: conn}), do: {:ok, conn}
end
