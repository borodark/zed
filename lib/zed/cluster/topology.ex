defmodule Zed.Cluster.Topology do
  @moduledoc """
  Render an IR's `cluster` declarations into the libcluster topology
  shape that the running BEAM apps consume.

  Each app's `config/runtime.exs` reads this through
  `Zed.Cluster.Topology.from_ir/1` (or, in production, from a static
  artifact zed writes during converge) and feeds it to libcluster's
  `Cluster.Supervisor`:

      config :libcluster, topologies: Zed.Cluster.Topology.from_ir(MyInfra.Demo.__zed_ir__())

  Cookie resolution is deliberately **not** performed here. The
  cookie is a `{:secret, ...}` reference at IR time; the actual
  cookie binary lives in the encrypted secrets dataset and is read
  at app-boot time by whichever release-config path the operator
  chose. This module returns the unresolved reference so the
  consumer can decide where the secret value comes from.

  This is the read-only bridge between Zed's IR and libcluster's
  expected map. No GenServer, no state, no side effects — pure
  transformation.
  """

  alias Zed.IR

  @type topology_map :: %{atom => keyword}

  @doc """
  Returns a topology map suitable for `config :libcluster, topologies: ...`.

  Empty map when the IR has no clusters declared.
  """
  @spec from_ir(IR.t()) :: topology_map
  def from_ir(%IR{clusters: clusters}) do
    Map.new(clusters, fn cluster ->
      {cluster.id,
       [
         strategy: Cluster.Strategy.Epmd,
         config: [hosts: cluster.config[:members] || []]
       ]}
    end)
  end

  @doc """
  Returns the unresolved cookie reference for a cluster, or `nil`
  if the cluster declared no cookie. Pass to a release-config helper
  that knows how to read from the secrets dataset.
  """
  @spec cookie_ref(IR.t(), atom) :: term | nil
  def cookie_ref(%IR{clusters: clusters}, cluster_id) do
    case Enum.find(clusters, &(&1.id == cluster_id)) do
      nil -> nil
      cluster -> cluster.config[:cookie]
    end
  end
end
