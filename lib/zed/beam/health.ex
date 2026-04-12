defmodule Zed.Beam.Health do
  @moduledoc """
  BEAM-native health checks.

  Uses distributed Erlang (:net_adm.ping, :rpc.call) and HTTP
  to verify deployed applications are running correctly.
  """

  @doc "Run all health checks for an app config. Returns {:ok, results} or {:error, failures}."
  def check(health_checks, app_config) do
    results = Enum.map(health_checks, fn {type, opts} ->
      run_check(type, opts, app_config)
    end)

    failures = Enum.filter(results, &match?({:fail, _, _}, &1))

    if failures == [] do
      {:ok, results}
    else
      {:error, failures}
    end
  end

  defp run_check(:beam_ping, opts, app_config) do
    node = app_config[:node_name]
    timeout = opts[:timeout] || 5_000

    if node do
      task = Task.async(fn -> :net_adm.ping(node) end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, :pong} -> {:pass, :beam_ping, :pong}
        {:ok, :pang} -> {:fail, :beam_ping, :pang}
        nil -> {:fail, :beam_ping, :timeout}
      end
    else
      {:skip, :beam_ping, :no_node_name}
    end
  end

  defp run_check(:rpc, opts, app_config) do
    node = app_config[:node_name]
    {mod, fun, args} = opts[:mfa]
    timeout = opts[:timeout] || 5_000

    if node do
      case :rpc.call(node, mod, fun, args, timeout) do
        {:badrpc, reason} -> {:fail, :rpc, reason}
        result -> {:pass, :rpc, result}
      end
    else
      {:skip, :rpc, :no_node_name}
    end
  end

  defp run_check(:http, opts, _app_config) do
    url = to_charlist(opts[:url] || opts["url"])
    expect = opts[:expect] || 200
    timeout = opts[:timeout] || 5_000

    :inets.start()

    case :httpc.request(:get, {url, []}, [{:timeout, timeout}], []) do
      {:ok, {{_, ^expect, _}, _, _}} -> {:pass, :http, expect}
      {:ok, {{_, status, _}, _, _}} -> {:fail, :http, {:unexpected_status, status}}
      {:error, reason} -> {:fail, :http, reason}
    end
  end

  defp run_check(:epmd, opts, _app_config) do
    host = opts[:host] || "localhost"
    timeout = opts[:timeout] || 5_000

    task = Task.async(fn ->
      case :erl_epmd.names(to_charlist(host)) do
        {:ok, names} -> {:pass, :epmd, names}
        {:error, reason} -> {:fail, :epmd, reason}
      end
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:fail, :epmd, :timeout}
    end
  end

  defp run_check(type, _opts, _config) do
    {:skip, type, :unknown_check_type}
  end
end
