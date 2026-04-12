defmodule Zed.Cluster do
  @moduledoc """
  Manage connections to remote Zed agents and execute operations.

  All remote operations use `:rpc.call` to the `Zed.Agent` GenServer
  running on each node. The Erlang cookie provides authentication.

  ## Connecting to Nodes

      # Connect to a single node
      Zed.Cluster.connect(:"zed@host2.local")

      # Connect to multiple nodes
      Zed.Cluster.connect_all([:"zed@host1", :"zed@host2", :"zed@host3"])

      # List connected nodes
      Zed.Cluster.nodes()

  ## Remote Operations

      # Run converge on remote node
      Zed.Cluster.converge(:"zed@host2", ir)
      Zed.Cluster.converge(:"zed@host2", ir, dry_run: true)

      # Get diff from remote
      Zed.Cluster.diff(:"zed@host2", ir)

      # Get status from remote
      Zed.Cluster.status(:"zed@host2", ir)

      # Rollback on remote
      Zed.Cluster.rollback(:"zed@host2", ir, "@latest")

  ## Multi-Node Operations

      # Converge on all connected nodes
      Zed.Cluster.converge_all(ir)

      # Get status from all nodes
      Zed.Cluster.status_all(ir)
  """

  require Logger

  @rpc_timeout 60_000

  # --- Connection Management ---

  @doc "Connect to a remote node."
  def connect(node) when is_atom(node) do
    case Node.connect(node) do
      true ->
        Logger.info("[Zed.Cluster] Connected to #{node}")
        :ok

      false ->
        {:error, :connection_failed}

      :ignored ->
        {:error, :not_distributed}
    end
  end

  @doc "Connect to multiple nodes. Returns map of results."
  def connect_all(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn node -> {node, connect(node)} end)
    |> Map.new()
  end

  @doc "List connected Zed nodes (nodes with Zed.Agent running)."
  def nodes do
    Node.list()
    |> Enum.filter(&agent_running?/1)
  end

  @doc "List all connected Erlang nodes."
  def all_nodes do
    Node.list()
  end

  @doc "Check if Zed.Agent is running on a node."
  def agent_running?(node) do
    case ping(node) do
      {:pong, _} -> true
      _ -> false
    end
  end

  # --- Remote Operations ---

  @doc "Ping remote agent."
  def ping(node) do
    rpc_call(node, Zed.Agent, :ping, [])
  end

  @doc "Get agent info from remote node."
  def info(node) do
    rpc_call(node, Zed.Agent, :info, [])
  end

  @doc "Run converge on remote node."
  def converge(node, ir, opts \\ []) do
    rpc_call(node, Zed.Agent, :converge, [ir, opts], :infinity)
  end

  @doc "Compute diff on remote node."
  def diff(node, ir) do
    rpc_call(node, Zed.Agent, :diff, [ir])
  end

  @doc "Get status from remote node."
  def status(node, ir) do
    rpc_call(node, Zed.Agent, :status, [ir])
  end

  @doc "Rollback on remote node."
  def rollback(node, ir, target) do
    rpc_call(node, Zed.Agent, :rollback, [ir, target], :infinity)
  end

  # --- Multi-Node Operations ---

  @doc "Converge on all connected nodes. Returns map of {node, result}."
  def converge_all(ir, opts \\ []) do
    nodes()
    |> Task.async_stream(
      fn node -> {node, converge(node, ir, opts)} end,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Map.new()
  end

  @doc "Get status from all connected nodes."
  def status_all(ir) do
    nodes()
    |> Task.async_stream(
      fn node -> {node, status(node, ir)} end,
      timeout: @rpc_timeout
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Map.new()
  end

  @doc "Get diff from all connected nodes."
  def diff_all(ir) do
    nodes()
    |> Task.async_stream(
      fn node -> {node, diff(node, ir)} end,
      timeout: @rpc_timeout
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Map.new()
  end

  @doc """
  Coordinated converge across all nodes with rollback on failure.

  If any node fails, all nodes that succeeded are rolled back.
  """
  def converge_coordinated(ir, opts \\ []) do
    target_nodes = Keyword.get(opts, :nodes, nodes())

    # Phase 1: Dry run on all nodes
    dry_results =
      target_nodes
      |> Enum.map(fn node -> {node, converge(node, ir, dry_run: true)} end)
      |> Map.new()

    dry_failures =
      dry_results
      |> Enum.filter(fn {_node, result} -> not match?({:dry_run, _}, result) end)

    if dry_failures != [] do
      {:error, :dry_run_failed, dry_failures}
    else
      # Phase 2: Execute on all nodes
      results =
        target_nodes
        |> Enum.reduce_while({:ok, []}, fn node, {:ok, succeeded} ->
          case converge(node, ir, opts) do
            {:ok, _} = result ->
              {:cont, {:ok, [{node, result} | succeeded]}}

            {:error, _, _, _} = error ->
              {:halt, {:error, node, error, succeeded}}
          end
        end)

      case results do
        {:ok, succeeded} ->
          {:ok, Map.new(succeeded)}

        {:error, failed_node, error, succeeded} ->
          # Rollback succeeded nodes
          rollback_results =
            succeeded
            |> Enum.map(fn {node, _} -> {node, rollback(node, ir, "@latest")} end)
            |> Map.new()

          {:error, :partial_failure, %{
            failed_node: failed_node,
            error: error,
            rolled_back: rollback_results
          }}
      end
    end
  end

  # --- Private ---

  defp rpc_call(node, module, function, args, timeout \\ @rpc_timeout) do
    case :rpc.call(node, module, function, args, timeout) do
      {:badrpc, reason} ->
        {:error, {:rpc_failed, node, reason}}

      result ->
        result
    end
  end
end
