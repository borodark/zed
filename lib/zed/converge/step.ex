defmodule Zed.Converge.Step do
  @moduledoc """
  A single convergence step — one atomic operation in the execution plan.

  Types: `:dataset`, `:app`, `:service`, `:snapshot`, `:jail`,
  `:jail_pkg`, `:jail_mount`, `:jail_svc`, `:tarfs`, `:file`.
  """

  defstruct [:id, :type, :action, :args, deps: []]

  @type t :: %__MODULE__{
          id: String.t(),
          type:
            :dataset
            | :app
            | :service
            | :snapshot
            | :jail
            | :jail_pkg
            | :jail_mount
            | :jail_svc
            | :tarfs
            | :file,
          action: :create | :update | :install | :start | :stop | :restart | :mount | :write,
          args: map(),
          deps: [String.t()]
        }
end
