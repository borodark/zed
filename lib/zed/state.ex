defmodule Zed.State do
  @moduledoc """
  Read current deployment state from ZFS properties.

  The source of truth for "what is deployed" is always ZFS user properties.
  This module reads them and returns a structured map.
  """

  alias Zed.ZFS.{Dataset, Property}

  @doc "Read the current state of all resources declared in the IR."
  def read(%Zed.IR{} = ir) do
    %{
      datasets: read_datasets(ir),
      apps: read_apps(ir)
    }
  end

  defp read_datasets(%Zed.IR{pool: pool, datasets: datasets}) do
    Map.new(datasets, fn node ->
      full_path = "#{pool}/#{node.id}"
      exists = Dataset.exists?(full_path)

      state =
        if exists do
          props = Property.get_all(full_path)
          mountpoint = Dataset.mountpoint(full_path)

          %{
            exists: true,
            mountpoint: mountpoint,
            properties: props
          }
        else
          %{exists: false, mountpoint: nil, properties: %{}}
        end

      {node.id, state}
    end)
  end

  defp read_apps(%Zed.IR{pool: pool, apps: apps}) do
    Map.new(apps, fn node ->
      ds_path = node.config[:dataset]
      full_path = if ds_path, do: "#{pool}/#{ds_path}", else: nil

      props =
        if full_path && Dataset.exists?(full_path) do
          Property.get_all(full_path)
        else
          %{}
        end

      state = %{
        version: props["version"],
        deployed_at: props["deployed_at"],
        health: props["health"],
        service: props["service"],
        node_name: props["node_name"],
        converge_gen: props["converge_gen"]
      }

      {node.id, state}
    end)
  end
end
