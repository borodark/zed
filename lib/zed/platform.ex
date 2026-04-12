defmodule Zed.Platform do
  @moduledoc """
  Behaviour for platform-specific operations.

  FreeBSD and illumos have different service management, isolation,
  package management, and boot environment tools. This behaviour
  abstracts them behind a common interface.
  """

  @type service_name :: String.t()

  @callback service_start(service_name()) :: :ok | {:error, term()}
  @callback service_stop(service_name()) :: :ok | {:error, term()}
  @callback service_restart(service_name()) :: :ok | {:error, term()}
  @callback service_status(service_name()) :: :running | :stopped | {:error, term()}
  @callback service_enable(service_name()) :: :ok | {:error, term()}
  @callback service_install(service_name(), config :: map()) :: :ok | {:error, term()}
end
