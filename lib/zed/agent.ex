defmodule Zed.Agent do
  @moduledoc """
  Agent GenServer that runs on each host.

  Handles local convergence operations and responds to remote
  requests from other Zed agents via `:rpc.call`.

  ## Starting the Agent

      # In your application supervisor
      children = [
        {Zed.Agent, name: :zed_agent}
      ]

      # Or manually
      Zed.Agent.start_link(name: :zed_agent)

  ## Local Operations

      Zed.Agent.converge(ir)
      Zed.Agent.converge(ir, dry_run: true)
      Zed.Agent.diff(ir)
      Zed.Agent.status(ir)
      Zed.Agent.rollback(ir, "@latest")

  ## Remote Operations (via Zed.Cluster)

      Zed.Cluster.converge(:"agent@host2", ir)
      Zed.Cluster.status(:"agent@host2", ir)
  """

  use GenServer

  require Logger

  defstruct [:node_name, :pool, :platform, deployments: %{}]

  @type t :: %__MODULE__{
          node_name: node(),
          pool: String.t() | nil,
          platform: module(),
          deployments: %{atom() => map()}
        }

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Run convergence for an IR locally."
  def converge(ir, opts \\ []) do
    GenServer.call(__MODULE__, {:converge, ir, opts}, :infinity)
  end

  @doc "Compute diff for an IR locally."
  def diff(ir) do
    GenServer.call(__MODULE__, {:diff, ir})
  end

  @doc "Get status for an IR locally."
  def status(ir) do
    GenServer.call(__MODULE__, {:status, ir})
  end

  @doc "Rollback to a previous version."
  def rollback(ir, target) do
    GenServer.call(__MODULE__, {:rollback, ir, target}, :infinity)
  end

  @doc "Get agent info."
  def info do
    GenServer.call(__MODULE__, :info)
  end

  @doc "Ping the agent (health check)."
  def ping do
    GenServer.call(__MODULE__, :ping)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    platform = Keyword.get(opts, :platform) || Zed.Platform.Detect.current()
    pool = Keyword.get(opts, :pool)

    state = %__MODULE__{
      node_name: node(),
      pool: pool,
      platform: platform,
      deployments: %{}
    }

    Logger.info("[Zed.Agent] Started on #{node()}")

    {:ok, state}
  end

  @impl true
  def handle_call({:converge, ir, opts}, _from, state) do
    result = Zed.Converge.run(ir, opts)

    # Track deployment
    new_deployments = Map.put(state.deployments, ir.name, %{
      last_converge: DateTime.utc_now(),
      result: result_status(result)
    })

    {:reply, result, %{state | deployments: new_deployments}}
  end

  @impl true
  def handle_call({:diff, ir}, _from, state) do
    result = Zed.Converge.Diff.compute(ir)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:status, ir}, _from, state) do
    result = Zed.State.read(ir)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:rollback, ir, target}, _from, state) do
    result = Zed.Converge.rollback(ir, target)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      node: state.node_name,
      pool: state.pool,
      platform: state.platform,
      deployments: state.deployments
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, {:pong, state.node_name}, state}
  end

  # --- Private ---

  defp result_status({:ok, _}), do: :ok
  defp result_status({:dry_run, _}), do: :dry_run
  defp result_status({:error, _, _, _}), do: :error
  defp result_status(_), do: :unknown
end
