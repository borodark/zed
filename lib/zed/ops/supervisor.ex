defmodule Zed.Ops.Supervisor do
  @moduledoc """
  Supervision tree for the `:ops` role (zedops release).

  Hosts:

    * `Task.Supervisor` for per-connection handlers (used by Socket).
    * `Zed.Ops.Socket` — the Unix-domain socket listener; peer-cred
      check on accept; dispatches to `Zed.Ops.Bastille.Handler`
      (A5a.4) for `:bastille_run`.

  Configuration is read from `Application.get_env(:zed,
  Zed.Ops.Socket, [])`:

      config :zed, Zed.Ops.Socket,
        path: "/var/run/zed/ops.sock",
        allowed_uids: [8501]   # zedweb's uid

  In dev / single-user setups (`:full` role) this supervisor is not
  started by `Zed.Application`, so the defaults never need to be set
  for `mix test`.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    socket_opts = socket_opts()

    children = [
      {Task.Supervisor, name: Zed.Ops.TaskSupervisor},
      {Zed.Ops.Socket, socket_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp socket_opts do
    base = Application.get_env(:zed, Zed.Ops.Socket, [])
    Keyword.put_new(base, :handler, {Zed.Ops.Bastille.Handler, :handle})
  end
end
