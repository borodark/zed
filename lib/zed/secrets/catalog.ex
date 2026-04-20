defmodule Zed.Secrets.Catalog do
  @moduledoc """
  Registry of known secret slots and storage modes.

  Every `{:secret, slot, ...}` reference in the DSL is validated against
  this catalog at compile time. Unknown slots fail with a list of known
  names; unknown storage modes fail with a pointer to the layer that
  will implement them.

  Layer A1 will extend each slot with generator metadata (algorithm,
  consumers, rotation policy). Layer A0 (this layer) records only the
  names and valid field atoms per slot.
  """

  # slot name => list of legal field atoms for that slot
  @slots %{
    beam_cookie: [:value],
    admin_passwd: [:value],
    ssh_host_ed25519: [:priv, :pub]
  }

  @implemented_storage [:local_file]

  # Storage modes recognized by the DSL but not yet implemented. The
  # atom value is the layer that will ship the implementation.
  @pending_storage %{
    probnik_vault: "D6",
    probnik_vault_pair: "D6",
    shamir_k_of_n: "D7"
  }

  @doc "All known slot atoms."
  def slots, do: Map.keys(@slots)

  @doc "True if `slot` is a known slot atom."
  def slot_known?(slot) when is_atom(slot), do: Map.has_key?(@slots, slot)
  def slot_known?(_), do: false

  @doc "Legal fields for `slot`, or `[]` if unknown."
  def fields(slot) when is_atom(slot), do: Map.get(@slots, slot, [])
  def fields(_), do: []

  @doc "True if `field` is valid for `slot`."
  def field_valid?(slot, field) when is_atom(slot) and is_atom(field) do
    field in fields(slot)
  end

  def field_valid?(_, _), do: false

  @doc "Storage modes the current codebase actually implements."
  def implemented_storage, do: @implemented_storage

  @doc "Storage modes recognized but not yet implemented (atom => layer tag)."
  def pending_storage, do: @pending_storage

  @doc "True if `mode` is any known storage atom (implemented or pending)."
  def storage_known?(mode) when is_atom(mode) do
    mode in @implemented_storage or Map.has_key?(@pending_storage, mode)
  end

  def storage_known?(_), do: false

  @doc "True if `mode` is implemented in the current codebase."
  def storage_implemented?(mode) when is_atom(mode), do: mode in @implemented_storage
  def storage_implemented?(_), do: false

  @doc "Layer tag (e.g. \"D6\") for a pending storage mode, or `nil`."
  def storage_pending_layer(mode) when is_atom(mode), do: Map.get(@pending_storage, mode)
  def storage_pending_layer(_), do: nil
end
