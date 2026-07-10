defmodule Zed.Secrets.Resolve do
  @moduledoc """
  Converge-time `{:secret, :slot[, :field]}` → binary resolution.

  Path C6's whole job. `Zed.Bootstrap` generates slot material once
  (via `Bootstrap.init/2`), stamps the location as a ZFS user
  property under `com.zed:secret.<slot>.<field>path`, and stores
  the bytes on the encrypted `<pool>/zed/secrets` dataset. This
  module reads that pointer at converge time and returns the bytes.

  Deterministic — given the same IR and ZFS state, the same slot
  reference always resolves to the same value. Fails closed — any
  missing property or unreadable file aborts converge.

  The Zed metadata dataset (e.g. `mac_zroot/zed`) is passed in
  explicitly by the caller. Executor threads it in through the
  `:jail_app :deploy` step args.
  """

  alias Zed.Secrets.Store
  alias Zed.ZFS.Property

  @type field :: :value | :priv | :pub | :cert | :key

  @doc """
  Resolve a slot (default field `:value`) against a Zed metadata
  dataset. Returns `{:ok, bytes}` on success.

  Errors:
    * `{:slot_property_missing, key}` — the ZFS property Bootstrap
      would have stamped isn't there. Usually means Bootstrap
      hasn't run for this slot yet.
    * `{:read_failed, path, reason}` — the property points at a
      path the resolver can't read (permissions, dataset unmounted,
      etc.).
    * `{:unknown_field, slot, field}` — the field name is not one
      of `:value`, `:priv`, `:pub`, `:cert`, or `:key`.
  """
  @spec resolve(dataset :: binary, slot :: atom, field :: field) ::
          {:ok, binary} | {:error, term}
  def resolve(dataset, slot, field \\ :value)
      when is_binary(dataset) and is_atom(slot) and is_atom(field) do
    resolve_from_props(Property.get_all(dataset), slot, field)
  end

  @doc """
  Same as `resolve/3` but takes an already-fetched properties map.
  Enables testing without a live ZFS dataset.
  """
  @spec resolve_from_props(map, atom, field) :: {:ok, binary} | {:error, term}
  def resolve_from_props(props, slot, field)
      when is_map(props) and is_atom(slot) and is_atom(field) do
    with {:ok, path} <- lookup_path(props, slot, field),
         {:ok, bytes} <- read_bytes(path) do
      {:ok, bytes}
    end
  end

  # Fields:
  #   :value → "secret.<slot>.path"       — single-value slots (e.g. beam_cookie)
  #   :priv  → "secret.<slot>.path"       — private key (keypair slots)
  #   :pub   → "secret.<slot>.pub_path"   — public part
  #   :cert  → "secret.<slot>.cert_path"  — cert (tls slots)
  #   :key   → "secret.<slot>.path"       — key file (tls slots — path is the key)
  defp lookup_path(props, slot, :value),
    do: fetch(props, "secret.#{slot}.path")

  defp lookup_path(props, slot, :priv),
    do: fetch(props, "secret.#{slot}.path")

  defp lookup_path(props, slot, :pub),
    do: fetch(props, "secret.#{slot}.pub_path")

  defp lookup_path(props, slot, :cert),
    do: fetch(props, "secret.#{slot}.cert_path")

  defp lookup_path(props, slot, :key),
    do: fetch(props, "secret.#{slot}.path")

  defp lookup_path(_props, slot, other),
    do: {:error, {:unknown_field, slot, other}}

  defp fetch(props, key) do
    case Map.get(props, key) do
      nil -> {:error, {:slot_property_missing, key}}
      "" -> {:error, {:slot_property_missing, key}}
      path -> {:ok, path}
    end
  end

  defp read_bytes(path) do
    case Store.read_value(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end
end
