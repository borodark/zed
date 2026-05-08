defmodule Zed.Converge.Health.Checker do
  @moduledoc """
  Behaviour for health-check probes invoked by `Zed.Converge.Health`.

  An implementation handles one or more probe types (`:http`,
  `:beam_ping`, etc.) and returns `:ok` when the probe succeeds or
  `{:error, reason}` when it fails or times out. Failures are
  retried by the orchestrator up to the configured `:max_retries`.
  """

  @callback check(host :: term(), type :: atom(), opts :: map(), timeout :: non_neg_integer()) ::
              :ok | {:error, term()}
end
