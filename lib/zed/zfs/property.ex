defmodule Zed.ZFS.Property do
  @moduledoc """
  ZFS user property operations.

  User properties under the `com.zed:` namespace are the sole state store
  for Zed. They travel with snapshots and `zfs send/receive`, replacing
  etcd, consul, and state files.
  """

  alias Zed.ZFS

  @namespace ZFS.namespace()

  @doc "Set a com.zed:key property on a dataset."
  def set(dataset, key, value) do
    ZFS.cmd(["set", "#{@namespace}:#{key}=#{value}", dataset])
  end

  @doc "Get a single com.zed:key property. Returns {:ok, value} or :not_set."
  def get(dataset, key) do
    case ZFS.cmd(["get", "-H", "-o", "value", "#{@namespace}:#{key}", dataset]) do
      {:ok, "-"} -> :not_set
      {:ok, value} -> {:ok, value}
      {:error, _, _} -> :not_set
    end
  end

  @doc "Get a property or raise."
  def get!(dataset, key) do
    case get(dataset, key) do
      {:ok, value} -> value
      :not_set -> raise "ZFS property #{@namespace}:#{key} not set on #{dataset}"
    end
  end

  @doc "Get all com.zed:* properties for a dataset as a map."
  def get_all(dataset) do
    case ZFS.cmd(["get", "-H", "-o", "property,value", "all", dataset]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, @namespace))
        |> Enum.map(fn line ->
          case String.split(line, "\t", parts: 2) do
            [prop, value] ->
              key = String.replace_prefix(prop, "#{@namespace}:", "")
              {key, String.trim(value)}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      {:error, _, _} ->
        %{}
    end
  end

  @doc "Set multiple properties at once."
  def set_many(dataset, props) when is_map(props) do
    Enum.each(props, fn {key, value} ->
      set(dataset, to_string(key), to_string(value))
    end)
  end
end
