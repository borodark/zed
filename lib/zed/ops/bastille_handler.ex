defmodule Zed.Ops.Bastille.Handler do
  @moduledoc """
  Ops-side handler for `:bastille_run` requests (A5a.4).

  Plugged into `Zed.Ops.Socket` as the dispatch function: receives a
  decoded request envelope from the socket, validates the action, and
  shells out via `Zed.Platform.Bastille.Runner.System`. The reply
  carries the `{output, exit_code}` tuple so the web side can apply
  the same `classify/1` logic it always has.

  Future actions (zfs, pf, audit append) plug into the same shape: a
  small `case` clause per action keeps the dispatch surface explicit.

  Why a separate module from `Zed.Ops.Socket`: the socket is a
  generic transport with peer-cred + framing; the handler is the
  zedops-specific business logic. Keeping them split makes it
  trivial to test the handler with a synthesised request map and no
  socket at all.
  """

  alias Zed.Platform.Bastille.Runner

  @doc """
  Handle a decoded request envelope. Returns the reply envelope to
  send back over the socket.

  Currently dispatches:

    * `:bastille_run` → `Runner.System.run/3` → `{output, exit_code}`
    * anything else  → `{:error, {:unknown_action, action}}`
  """
  def handle({:zedops, :v1, request_id, :bastille_run, payload, _signature}) do
    with {:ok, sub} <- fetch(payload, :subcommand),
         {:ok, argv} <- fetch(payload, :argv),
         {:ok, opts} <- fetch(payload, :opts) do
      result = runner().run(sub, argv, opts)
      {:zedops_reply, request_id, {:ok, result}}
    else
      {:error, reason} -> {:zedops_reply, request_id, {:error, reason}}
    end
  end

  def handle({:zedops, :v1, request_id, action, _payload, _signature}) do
    {:zedops_reply, request_id, {:error, {:unknown_action, action}}}
  end

  def handle(other) do
    {:zedops_reply, "unknown", {:error, {:bad_request, other}}}
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch(_, key), do: {:error, {:missing_field, key}}

  # The handler reads its runner from its own config key (not the
  # one shared with `Zed.Platform.Bastille`) so a single test process
  # can have one side of the boundary using `Runner.OpsClient` and
  # the other side using `Runner.Mock`.
  defp runner do
    :zed
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:runner, Runner.System)
  end
end
