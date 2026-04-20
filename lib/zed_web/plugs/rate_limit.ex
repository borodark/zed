defmodule ZedWeb.Plugs.RateLimit do
  @moduledoc """
  Simple per-IP sliding-window rate limiter for API endpoints.

  ETS-backed, no GenServer — serialisation is per-key via
  `:ets.update_counter/4` atomic semantics. Good enough for deterring
  OTT brute-force noise; not a general-purpose rate limiter.

  Plug opts:
    - `:max` (required) — max requests allowed in the window
    - `:window` (required) — sliding window in seconds
    - `:key` (default `:ip`) — `:ip` to key on `conn.remote_ip`, or a
      function `(Plug.Conn.t() -> term())` for custom keys

  On over-limit: returns `429 Too Many Requests` with
  `{"error": "rate_limited"}` and halts the conn.
  """

  @behaviour Plug

  import Plug.Conn

  @table :zed_rate_limit

  @impl true
  def init(opts) do
    %{
      max: Keyword.fetch!(opts, :max),
      window: Keyword.fetch!(opts, :window),
      key: Keyword.get(opts, :key, :ip)
    }
  end

  @impl true
  def call(conn, %{max: max, window: window, key: key_kind}) do
    ensure_table()

    key = rate_key(conn, key_kind)
    now = :os.system_time(:second)
    window_start = now - window

    fresh_count =
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, [now]})
          1

        [{^key, timestamps}] ->
          fresh = [now | Enum.filter(timestamps, &(&1 >= window_start))]
          :ets.insert(@table, {key, fresh})
          length(fresh)
      end

    if fresh_count > max do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, ~s({"error":"rate_limited"}))
      |> halt()
    else
      conn
    end
  end

  defp rate_key(conn, :ip) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp rate_key(conn, fun) when is_function(fun, 1), do: fun.(conn)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])

      _ref ->
        @table
    end
  end
end
