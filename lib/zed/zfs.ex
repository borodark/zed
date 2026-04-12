defmodule Zed.ZFS do
  @moduledoc """
  ZFS command interface.

  All operations use `System.cmd/3` against the stable ZFS CLI tools.
  Identical interface on FreeBSD and illumos — ZFS is the one thing
  that doesn't need a platform backend.
  """

  @namespace "com.zed"

  def namespace, do: @namespace

  @doc "Run a zfs command, returning {:ok, output} or {:error, output, code}."
  def cmd(args, opts \\ []) do
    zfs_bin = opts[:zfs_bin] || "zfs"

    case System.cmd(zfs_bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, String.trim(output), code}
    end
  end

  @doc "Run a zpool command."
  def pool_cmd(args, opts \\ []) do
    zpool_bin = opts[:zpool_bin] || "zpool"

    case System.cmd(zpool_bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, String.trim(output), code}
    end
  end
end
