defmodule Zed.Platform.Bastille.Runner.OpsClient do
  @moduledoc """
  Bastille runner that dispatches over the zedweb → zedops Unix socket
  (A5a.4).

  Implements the `Zed.Platform.Bastille.Runner` behaviour: takes a
  subcommand atom + argv + opts, returns `{output, exit_code}`. The
  same shape as `Runner.System` so `Zed.Platform.Bastille` doesn't
  care which side of the boundary the actual shellout happens on.

  The wire envelope is `{:zedops, :v1, request_id, :bastille_run,
  %{subcommand, argv, opts}, signature}`; on the ops side
  `Zed.Ops.Bastille.Handler` decodes it and calls `Runner.System` to
  run the actual `bastille` invocation. Reply is
  `{:zedops_reply, request_id, {:ok, {output, exit_code}}}` for the
  happy path.

  Transport failures are surfaced as a synthesised `{output, 255}`
  with a diagnostic message, so callers (which only know how to
  classify exit codes) get a structured error rather than a crash.
  255 is conventionally "command not found / could not run" in shell
  land.
  """

  @behaviour Zed.Platform.Bastille.Runner

  alias Zed.Web.OpsClient

  @impl true
  def run(subcommand, argv, opts) do
    request_id = generate_request_id()
    payload = %{subcommand: subcommand, argv: argv, opts: opts}

    case OpsClient.call(request_id, :bastille_run, payload) do
      {:zedops_reply, ^request_id, {:ok, {output, exit_code}}}
      when is_binary(output) and is_integer(exit_code) ->
        {output, exit_code}

      {:zedops_reply, ^request_id, {:error, reason}} ->
        {transport_diagnostic("ops error: #{inspect(reason)}"), 255}

      {:zedops_reply, other_id, _} ->
        {transport_diagnostic("request_id mismatch: sent=#{request_id} got=#{inspect(other_id)}"),
         255}

      {:error, reason} ->
        {transport_diagnostic("ops transport: #{inspect(reason)}"), 255}

      other ->
        {transport_diagnostic("ops unexpected: #{inspect(other)}"), 255}
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp transport_diagnostic(msg) do
    "zedops:#{msg}"
  end
end
