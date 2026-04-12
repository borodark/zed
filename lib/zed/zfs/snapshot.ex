defmodule Zed.ZFS.Snapshot do
  @moduledoc """
  ZFS snapshot operations.

  Snapshots are the rollback mechanism. Before every deploy, Zed takes
  a snapshot. Rollback is `zfs rollback` — instant, atomic, constant time.
  """

  alias Zed.ZFS

  @doc "Create a snapshot."
  def create(dataset, name) do
    ZFS.cmd(["snapshot", "#{dataset}@#{name}"])
  end

  @doc "Create a snapshot with a generated name."
  def create_deploy_snapshot(dataset, version) do
    ts = timestamp()
    name = "zed-deploy-#{version}-#{ts}"
    create(dataset, name)
    {:ok, "#{dataset}@#{name}"}
  end

  @doc "Rollback to a snapshot. Instant and atomic."
  def rollback(snapshot) do
    ZFS.cmd(["rollback", "-r", snapshot])
  end

  @doc "List snapshots for a dataset, most recent last."
  def list(dataset) do
    case ZFS.cmd(["list", "-H", "-o", "name,creation", "-t", "snapshot",
                   "-s", "creation", "-r", dataset]) do
      {:ok, ""} ->
        []

      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, "\t", parts: 2) do
            [name, creation] -> %{name: name, creation: String.trim(creation)}
            [name] -> %{name: name, creation: nil}
          end
        end)

      {:error, _, _} ->
        []
    end
  end

  @doc "Destroy a snapshot."
  def destroy(snapshot) do
    ZFS.cmd(["destroy", snapshot])
  end

  @doc "Find the latest snapshot matching a prefix."
  def find_latest(dataset, prefix \\ "zed-") do
    dataset
    |> list()
    |> Enum.filter(fn s -> String.contains?(s.name, "@#{prefix}") end)
    |> List.last()
  end

  @doc "Prune old snapshots, keeping the most recent `keep` count."
  def prune(dataset, prefix, keep) do
    snaps =
      dataset
      |> list()
      |> Enum.filter(fn s -> String.contains?(s.name, "@#{prefix}") end)

    to_delete = Enum.drop(snaps, -keep)

    Enum.each(to_delete, fn s ->
      destroy(s.name)
    end)

    length(to_delete)
  end

  defp timestamp do
    {{y, m, d}, {h, min, s}} = :calendar.universal_time()
    :io_lib.format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0B", [y, m, d, h, min, s])
    |> IO.iodata_to_binary()
  end
end
