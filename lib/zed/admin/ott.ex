defmodule Zed.Admin.OTT do
  @moduledoc """
  One-time token issuer and consumer for QR-driven admin login.

  ETS-backed for fast lookups; a GenServer serialises issue/consume so
  single-use semantics hold under concurrent redeem attempts (same OTT
  racing from two devices → exactly one wins).

  Tokens are 256-bit cryptographic random, base64url-encoded without
  padding (~43 characters). Brute force is infeasible within the TTL
  window; rate limiting on the redeem endpoint (`/admin/qr-login`)
  exists to deter noise, not to gate the crypto.

  Entries:
    `{ott, %{created_at, expires_at, issued_by, used, user}}`
  """

  use GenServer

  @table :zed_admin_otts
  @default_ttl_seconds 120

  # --- public API ---

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Issue a new one-time token.

  Options:
    - `:ttl_seconds` (default 120)
    - `:issued_by` (default `:admin_panel`) — audit tag
    - `:user` (default `:admin`) — subject the token authenticates as

  Returns `{:ok, %{ott: token, expires_at: unix_ts}}`.
  """
  def issue(opts \\ []) do
    GenServer.call(__MODULE__, {:issue, opts})
  end

  @doc """
  Consume a token. Atomic: only one caller sees `{:ok, meta}`; any
  subsequent or concurrent consumer gets `{:error, :used}`.
  """
  def consume(ott) when is_binary(ott) do
    GenServer.call(__MODULE__, {:consume, ott})
  end

  # --- callbacks ---

  @impl true
  def init(_) do
    ensure_table()
    {:ok, :no_state}
  end

  @impl true
  def handle_call({:issue, opts}, _from, state) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    now = :os.system_time(:second)
    ott = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    meta = %{
      created_at: now,
      expires_at: now + ttl,
      issued_by: Keyword.get(opts, :issued_by, :admin_panel),
      used: false,
      user: Keyword.get(opts, :user, :admin)
    }

    :ets.insert(@table, {ott, meta})

    {:reply, {:ok, %{ott: ott, expires_at: meta.expires_at}}, state}
  end

  def handle_call({:consume, ott}, _from, state) do
    now = :os.system_time(:second)

    reply =
      case :ets.lookup(@table, ott) do
        [] ->
          {:error, :not_found}

        [{^ott, %{used: true}}] ->
          {:error, :used}

        [{^ott, %{expires_at: exp}}] when exp < now ->
          :ets.delete(@table, ott)
          {:error, :expired}

        [{^ott, meta}] ->
          updated = %{meta | used: true}
          :ets.insert(@table, {ott, updated})
          {:ok, updated}
      end

    {:reply, reply, state}
  end

  # --- internals ---

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

      _ref ->
        @table
    end
  end
end
