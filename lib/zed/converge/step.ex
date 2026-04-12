defmodule Zed.Converge.Step do
  @moduledoc """
  A single convergence step — one atomic operation in the execution plan.
  """

  defstruct [:id, :type, :action, :args, deps: []]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :dataset | :app | :service | :snapshot,
          action: :create | :update | :start | :stop | :restart,
          args: map(),
          deps: [String.t()]
        }
end
