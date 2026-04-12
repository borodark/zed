defmodule Zed.IR do
  @moduledoc """
  Deployment intermediate representation.

  Built by the DSL at compile time, consumed by the convergence engine at runtime.
  Each node represents a managed resource: dataset, app, jail, zone, etc.
  """

  defstruct [
    :name,
    :pool,
    datasets: [],
    apps: [],
    jails: [],
    zones: [],
    snapshot_config: %{before_deploy: false, keep: 5},
    clusters: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          pool: String.t(),
          datasets: [Zed.IR.Node.t()],
          apps: [Zed.IR.Node.t()],
          jails: [Zed.IR.Node.t()],
          zones: [Zed.IR.Node.t()],
          snapshot_config: map(),
          clusters: [Zed.IR.Node.t()]
        }

  def dataset_ids(%__MODULE__{datasets: ds}), do: Enum.map(ds, & &1.id)

  def app_ids(%__MODULE__{apps: apps}), do: Enum.map(apps, & &1.id)

  def find_dataset(%__MODULE__{datasets: ds}, id) do
    Enum.find(ds, fn n -> n.id == id end)
  end

  def find_app(%__MODULE__{apps: apps}, id) do
    Enum.find(apps, fn n -> n.id == id end)
  end
end
