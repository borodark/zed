defmodule Zed.Ops.Supervisor do
  @moduledoc """
  Supervision tree for the `:ops` role (zedops release).

  Will host:

    * `Zed.Ops.Socket` — Unix-domain socket listener with `getpeereid`
      peer-credential check. Built in A5a.2.

    * `Zed.Ops.Audit` — append-only JSON-Lines writer to
      `<base>/zed/audit.log`. Built in A5b.3.

    * `Zed.Ops.Bastille.Worker` — the actual doas/bastille shellout
      pool. Replaces the in-process `Zed.Platform.Bastille.Runner` for
      production. Built in A5a.4.

  For A5a.1 the supervisor starts empty — the role plumbing has to
  exist before the children that ride on it. The empty branch is also
  the smoke test that the role dispatch in `Zed.Application` wired up
  correctly.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end
end
