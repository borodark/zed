defmodule Zed.IR.Node do
  @moduledoc """
  A single managed resource in the deployment IR.
  """

  defstruct [:id, :type, config: %{}, deps: []]

  @type t :: %__MODULE__{
          id: atom() | String.t(),
          type: :dataset | :app | :jail | :zone | :cluster,
          config: map(),
          deps: [atom() | String.t()]
        }
end
