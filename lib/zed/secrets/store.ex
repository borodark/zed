defmodule Zed.Secrets.Store do
  @moduledoc """
  Tier-1 secret storage: value bytes on disk under restrictive mode.

  Values live at `<mountpoint>/<slot>` (single-value slots) or
  `<mountpoint>/<slot>` + `<mountpoint>/<slot>.pub` (keypair slots).
  The mountpoint is the encrypted ZFS dataset `<base>/zed/secrets`;
  restricting file mode is a defence-in-depth layer on top of the ZFS
  encryption.

  Tier 2 (fingerprint metadata) lives in ZFS user properties and is
  managed in `Zed.Bootstrap.stamp_slot/5` via `Zed.ZFS.Property`.
  Tier 3 (archive on rotation) is future work inside this module.
  """

  @default_mode 0o400

  @doc """
  Write `bytes` to `path`, create parent dirs, set mode (default `0400`).
  """
  def write_value(path, bytes, mode \\ @default_mode)
      when is_binary(path) and is_binary(bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    File.chmod!(path, mode)
    :ok
  end

  @doc "Read bytes from `path`. Returns `{:ok, bytes}` or `{:error, reason}`."
  def read_value(path) when is_binary(path), do: File.read(path)

  @doc "Remove a file if it exists. Returns `:ok`."
  def destroy(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "`sha256:<lowercase hex>` fingerprint of `bytes`."
  def fingerprint(bytes) when is_binary(bytes) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    "sha256:#{hash}"
  end

  @doc "True if `path` exists and is a regular file."
  def file_exists?(path) when is_binary(path), do: File.regular?(path)
end
