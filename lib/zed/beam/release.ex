defmodule Zed.Beam.Release do
  @moduledoc """
  Mix release deployment operations.

  Handles unpacking release tarballs, managing the `current` symlink,
  and verifying release integrity.
  """

  @doc "Deploy a release tarball to a dataset mountpoint."
  def deploy(tarball_path, version, mountpoint) do
    releases_dir = Path.join(mountpoint, "releases")
    version_dir = Path.join(releases_dir, version)

    File.mkdir_p!(version_dir)

    case System.cmd("tar", ["xzf", tarball_path, "-C", version_dir], stderr_to_stdout: true) do
      {_, 0} ->
        update_current_symlink(mountpoint, version_dir)
        {:ok, version_dir}

      {output, code} ->
        {:error, {:unpack_failed, code, output}}
    end
  end

  @doc """
  Update the `current` symlink to point to a version directory.

  Uses a RELATIVE symlink target (`releases/<version>`) rather than
  an absolute path. Relative works both from the host filesystem and
  from inside a jail whose rootfs is at a different absolute path —
  critical for the Path C jail-contained app deployment, where the
  host sees `<jails_dir>/<jail>/root/opt/<app>/current` but the jail
  sees `/opt/<app>/current`, and the symlink's stored target string
  must resolve correctly from both perspectives.
  """
  def update_current_symlink(mountpoint, version_dir) do
    current = Path.join(mountpoint, "current")
    relative_target = Path.relative_to(version_dir, mountpoint)
    File.rm(current)
    File.ln_s!(relative_target, current)
  end

  @doc "List deployed versions in a releases directory."
  def list_versions(mountpoint) do
    releases_dir = Path.join(mountpoint, "releases")

    case File.ls(releases_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn e ->
          Path.join(releases_dir, e) |> File.dir?()
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "Get the currently active version from the symlink."
  def current_version(mountpoint) do
    current = Path.join(mountpoint, "current")

    case File.read_link(current) do
      {:ok, target} -> Path.basename(target)
      {:error, _} -> nil
    end
  end
end
