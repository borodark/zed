defmodule Zed.ZFS.Replicate do
  @moduledoc """
  ZFS replication via `zfs send | zfs receive`.

  Replicates datasets (with all properties including com.zed:*)
  between hosts. The deployment state travels with the data.

  ## Local Replication (same host, different pool)

      Zed.ZFS.Replicate.local("jeff/apps/web@snap", "backup/apps/web")

  ## Remote Replication (via SSH)

      # Send to remote host
      Zed.ZFS.Replicate.send_ssh("jeff/apps/web@snap", "user@host2", "tank/apps/web")

      # Incremental send (only changes since last snapshot)
      Zed.ZFS.Replicate.send_ssh_incremental(
        "jeff/apps/web",
        "@snap1",
        "@snap2",
        "user@host2",
        "tank/apps/web"
      )

  ## Via Distributed Erlang

      # Uses Port to stream between nodes
      Zed.ZFS.Replicate.send_to_node(:"zed@host2", "jeff/apps/web@snap", "tank/apps/web")
  """

  alias Zed.ZFS
  alias Zed.ZFS.Snapshot

  require Logger

  @doc """
  Replicate a snapshot locally to another dataset.

  Uses: zfs send <snapshot> | zfs receive <target>
  """
  def local(snapshot, target_dataset, opts \\ []) do
    recv_opts = build_recv_opts(opts)

    cmd = "zfs send #{snapshot} | zfs receive #{recv_opts}#{target_dataset}"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("[Replicate] Local: #{snapshot} → #{target_dataset}")
        {:ok, target_dataset}

      {output, code} ->
        {:error, {:replicate_failed, code, output}}
    end
  end

  @doc """
  Send a snapshot to a remote host via SSH.

  Uses: zfs send <snapshot> | ssh <host> zfs receive <target>
  """
  def send_ssh(snapshot, remote_host, target_dataset, opts \\ []) do
    recv_opts = build_recv_opts(opts)
    ssh_opts = Keyword.get(opts, :ssh_opts, "")

    cmd = "zfs send #{snapshot} | ssh #{ssh_opts} #{remote_host} zfs receive #{recv_opts}#{target_dataset}"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("[Replicate] SSH: #{snapshot} → #{remote_host}:#{target_dataset}")
        {:ok, {remote_host, target_dataset}}

      {output, code} ->
        {:error, {:ssh_send_failed, code, output}}
    end
  end

  @doc """
  Incremental send via SSH (only changes between two snapshots).

  Uses: zfs send -i <snap1> <dataset>@<snap2> | ssh <host> zfs receive <target>
  """
  def send_ssh_incremental(dataset, from_snap, to_snap, remote_host, target_dataset, opts \\ []) do
    recv_opts = build_recv_opts(opts)
    ssh_opts = Keyword.get(opts, :ssh_opts, "")

    from = "#{dataset}#{from_snap}"
    to = "#{dataset}#{to_snap}"

    cmd = "zfs send -i #{from} #{to} | ssh #{ssh_opts} #{remote_host} zfs receive #{recv_opts}#{target_dataset}"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("[Replicate] Incremental: #{from}..#{to} → #{remote_host}:#{target_dataset}")
        {:ok, {remote_host, target_dataset}}

      {output, code} ->
        {:error, {:incremental_send_failed, code, output}}
    end
  end

  @doc """
  Receive a snapshot from a remote host via SSH.

  Uses: ssh <host> zfs send <snapshot> | zfs receive <target>
  """
  def receive_ssh(remote_host, remote_snapshot, target_dataset, opts \\ []) do
    recv_opts = build_recv_opts(opts)
    ssh_opts = Keyword.get(opts, :ssh_opts, "")

    cmd = "ssh #{ssh_opts} #{remote_host} zfs send #{remote_snapshot} | zfs receive #{recv_opts}#{target_dataset}"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("[Replicate] Received: #{remote_host}:#{remote_snapshot} → #{target_dataset}")
        {:ok, target_dataset}

      {output, code} ->
        {:error, {:ssh_receive_failed, code, output}}
    end
  end

  @doc """
  Sync a dataset to remote, creating snapshot if needed.

  1. Creates a deploy snapshot on source
  2. Sends to remote
  3. Returns snapshot name for tracking
  """
  def sync_to_remote(source_dataset, remote_host, target_dataset, opts \\ []) do
    version = Keyword.get(opts, :version, "sync")

    with {:ok, snapshot} <- Snapshot.create_deploy_snapshot(source_dataset, version),
         {:ok, _} <- send_ssh(snapshot, remote_host, target_dataset, opts) do
      {:ok, %{snapshot: snapshot, remote: {remote_host, target_dataset}}}
    end
  end

  @doc """
  Estimate the size of a send stream (for progress reporting).

  Uses: zfs send -nv <snapshot>
  """
  def estimate_size(snapshot) do
    case ZFS.cmd(["send", "-nv", snapshot]) do
      {:ok, output} ->
        # Parse output like "total estimated size is 1.5G"
        case Regex.run(~r/size is ([\d.]+)([KMGT]?)/, output) do
          [_, size, unit] ->
            {:ok, parse_size(size, unit)}

          _ ->
            {:ok, :unknown}
        end

      {:error, msg, code} ->
        {:error, {:estimate_failed, code, msg}}
    end
  end

  @doc """
  List common snapshots between local and remote dataset.

  Useful for determining incremental send base.
  """
  def find_common_snapshot(local_dataset, remote_host, remote_dataset) do
    local_snaps =
      Snapshot.list(local_dataset)
      |> Enum.map(& &1.name)
      |> Enum.map(&snapshot_short_name/1)
      |> MapSet.new()

    # Get remote snapshots via SSH
    case System.cmd("ssh", [remote_host, "zfs", "list", "-t", "snapshot", "-H", "-o", "name", "-r", remote_dataset], stderr_to_stdout: true) do
      {output, 0} ->
        remote_snaps =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(&snapshot_short_name/1)
          |> MapSet.new()

        common = MapSet.intersection(local_snaps, remote_snaps)

        if MapSet.size(common) > 0 do
          # Return the most recent common snapshot
          {:ok, Enum.max(common)}
        else
          {:ok, nil}
        end

      {output, _} ->
        {:error, {:remote_list_failed, output}}
    end
  end

  # --- Private ---

  defp build_recv_opts(opts) do
    flags = []
    flags = if Keyword.get(opts, :force, false), do: ["-F" | flags], else: flags
    flags = if Keyword.get(opts, :unmounted, false), do: ["-u" | flags], else: flags

    case flags do
      [] -> ""
      _ -> Enum.join(flags, " ") <> " "
    end
  end

  defp parse_size(size_str, unit) do
    size = String.to_float(size_str)

    multiplier =
      case unit do
        "K" -> 1024
        "M" -> 1024 * 1024
        "G" -> 1024 * 1024 * 1024
        "T" -> 1024 * 1024 * 1024 * 1024
        _ -> 1
      end

    trunc(size * multiplier)
  end

  defp snapshot_short_name(full_name) do
    case String.split(full_name, "@") do
      [_dataset, snap] -> snap
      _ -> full_name
    end
  end
end
