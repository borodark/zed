defmodule Zed.Converge.Health.DefaultChecker do
  @moduledoc """
  Built-in `Zed.Converge.Health.Checker` implementation.

  Probe types:
    * `:http`      — opts `%{url: String.t(), expect: 100..599}`. Uses
                     `:httpc`; requires `:inets` (started by zed at boot).
    * `:beam_ping` — opts `%{node: atom()}`. Uses `:net_adm.ping/1`.
                     Returns `:ok` on `:pong`, `{:error, :pang}` on `:pang`.
  """

  @behaviour Zed.Converge.Health.Checker

  @impl true
  def check(_host, :http, %{url: url} = opts, timeout) do
    expect = Map.get(opts, :expect, 200)
    url_charlist = String.to_charlist(url)
    httpc_opts = [timeout: timeout, connect_timeout: timeout]

    Application.ensure_all_started(:inets)

    case :httpc.request(:get, {url_charlist, []}, httpc_opts, []) do
      {:ok, {{_, status, _}, _, _}} when status == expect ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status, expect: expect}}

      {:error, reason} ->
        {:error, {:http_request, reason}}
    end
  end

  def check(_host, :beam_ping, %{node: node}, _timeout) do
    case :net_adm.ping(node) do
      :pong -> :ok
      :pang -> {:error, {:beam_ping, :pang, node}}
    end
  end

  def check(host, type, _opts, _timeout) do
    {:error, {:unknown_check_type, type, host}}
  end
end
