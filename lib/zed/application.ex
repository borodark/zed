defmodule Zed.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Phoenix PubSub is always started so LiveView can run in tests
      # without the endpoint. The endpoint itself is NOT supervised
      # here — `zed serve` starts it under its own supervisor, so that
      # one-shot verbs (bootstrap init, status, etc.) do not pay the
      # cost of a listening socket.
      {Phoenix.PubSub, name: Zed.PubSub}
    ]

    opts = [strategy: :one_for_one, name: Zed.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
