defmodule Zed.ZFS.Dataset do
  @moduledoc """
  ZFS dataset operations: create, destroy, list, check existence.
  """

  alias Zed.ZFS

  @doc "Check if a dataset exists."
  def exists?(dataset) do
    case ZFS.cmd(["list", "-H", "-o", "name", dataset]) do
      {:ok, _} -> true
      {:error, _, _} -> false
    end
  end

  @doc "Create a dataset with optional properties."
  def create(dataset, props \\ %{}) do
    prop_args =
      Enum.flat_map(props, fn {key, value} ->
        ["-o", "#{key}=#{value}"]
      end)

    ZFS.cmd(["create", "-p"] ++ prop_args ++ [dataset])
  end

  @doc "List datasets under a parent, returning names."
  def list(parent) do
    case ZFS.cmd(["list", "-H", "-o", "name", "-r", parent]) do
      {:ok, output} -> String.split(output, "\n", trim: true)
      {:error, _, _} -> []
    end
  end

  @doc "Get a native ZFS property (not a user property)."
  def get_property(dataset, property) do
    case ZFS.cmd(["get", "-H", "-o", "value", property, dataset]) do
      {:ok, value} -> {:ok, value}
      {:error, _, _} -> :error
    end
  end

  @doc "Set a native ZFS property."
  def set_property(dataset, property, value) do
    ZFS.cmd(["set", "#{property}=#{value}", dataset])
  end

  @doc "Destroy a dataset."
  def destroy(dataset) do
    ZFS.cmd(["destroy", "-r", dataset])
  end

  @doc "Get the mountpoint of a dataset."
  def mountpoint(dataset) do
    case get_property(dataset, "mountpoint") do
      {:ok, mp} -> mp
      :error -> nil
    end
  end
end
