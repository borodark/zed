defmodule Zed.Converge.Health.DefaultChecker do
  @moduledoc """
  Built-in `Zed.Converge.Health.Checker` implementation.

  Probe types:
    * `:tcp`       — opts `%{host: charlist | String.t(), port: 1..65535}`.
                     Opens a TCP socket with `:gen_tcp.connect/4`, closes
                     immediately. Connection refused, host unreachable,
                     or timeout returns `{:error, reason}`. The default
                     liveness probe — port open is enough for "the
                     service is listening."
    * `:beam_ping` — opts `%{node: atom()}`. Uses `:net_adm.ping/1`.
                     Returns `:ok` on `:pong`, `{:error, :pang}` on `:pang`.

  HTTP probes are not built-in. Apps that need 200-OK semantics should
  pass a custom `:checker` module — keeping `:httpc` out of the default
  path means no `:inets` startup tax for deploys that only need TCP
  liveness.
  """

  @behaviour Zed.Converge.Health.Checker

  @impl true
  def check(_host, :tcp, %{host: target_host, port: port}, timeout)
      when is_integer(port) and port in 1..65535 do
    target = to_charlist(target_host)

    case :gen_tcp.connect(target, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, {:tcp_connect, target_host, port, reason}}
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
