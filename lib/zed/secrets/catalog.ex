defmodule Zed.Secrets.Catalog do
  @moduledoc """
  Registry of known secret slots and storage modes.

  A slot declares its valid `fields`, its generation `algo`, and the
  service `consumers` that must restart when the slot rotates. DSL
  references like `{:secret, :beam_cookie}` are validated against this
  catalog at compile time (see `Zed.IR.Validate.check_secret_refs/1`).

  Algo atoms map to functions in `Zed.Secrets.Generate`.

  Future layers extend the catalog:
    - Layer D6 adds slots with `storage: :probnik_vault_pair`
      (`secrets_ds_passphrase`, `replication_root_key`).
    - Layer D7 adds slots with `storage: :shamir_k_of_n`
      (`pool_encryption_key`).
  """

  # slot => %{fields, algo, consumers}
  #   fields:    list of valid field atoms for this slot
  #   algo:      atom dispatched to Zed.Secrets.Generate.by_algo/2
  #   consumers: CSV of service atoms (used to plan restarts on rotation)
  @slots %{
    beam_cookie: %{
      fields: [:value],
      algo: :random_256_b64,
      consumers: [:beam]
    },
    admin_passwd: %{
      fields: [:value],
      algo: :pbkdf2_sha256,
      consumers: [:zed_web]
    },
    ssh_host_ed25519: %{
      fields: [:priv, :pub],
      algo: :ed25519,
      consumers: [:sshd]
    },
    tls_selfsigned: %{
      fields: [:cert, :key],
      algo: :selfsigned_tls,
      consumers: [:zed_web]
    },
    # ------------------------------------------------------------------
    # Demo-cluster slots (specs/demo-cluster-plan.md). The cluster
    # cookie is shared by all five BEAM jails so they form one
    # distributed Erlang topology. The pg/ch admin passwords seed the
    # database jails before they're handed to the apps that consume
    # them. Alpaca creds are split into id+secret because Alpaca's API
    # requires both as separate values; modelling them as one slot with
    # two fields keeps the rotation atomic.
    demo_cluster_cookie: %{
      fields: [:value],
      algo: :random_256_b64,
      consumers: [:beam]
    },
    pg_admin_passwd: %{
      fields: [:value],
      algo: :pbkdf2_sha256,
      consumers: [:postgres]
    },
    ch_admin_passwd: %{
      fields: [:value],
      algo: :pbkdf2_sha256,
      consumers: [:clickhouse]
    },
    livebook_passwd: %{
      fields: [:value],
      algo: :random_256_b64,
      consumers: [:livebook]
    }
    # NB: Alpaca creds aren't a generated slot — they come from the
    # operator's Alpaca dashboard. Demo passes them via the exmc jail's
    # env (ALPACA_API_KEY_ID / ALPACA_SECRET_KEY). Adding a slot here
    # would require a :user_supplied algo we don't have yet.
  }

  @implemented_storage [:local_file]

  @pending_storage %{
    probnik_vault: "D6",
    probnik_vault_pair: "D6",
    shamir_k_of_n: "D7"
  }

  @doc "All known slot atoms."
  def slots, do: Map.keys(@slots)

  @doc "Full spec for a slot, or `nil` if unknown."
  def slot_spec(slot) when is_atom(slot), do: Map.get(@slots, slot)
  def slot_spec(_), do: nil

  @doc "True if `slot` is a known slot atom."
  def slot_known?(slot) when is_atom(slot), do: Map.has_key?(@slots, slot)
  def slot_known?(_), do: false

  @doc "Legal fields for `slot`, or `[]` if unknown."
  def fields(slot) when is_atom(slot) do
    case Map.get(@slots, slot) do
      %{fields: f} -> f
      _ -> []
    end
  end

  def fields(_), do: []

  @doc "True if `field` is valid for `slot`."
  def field_valid?(slot, field) when is_atom(slot) and is_atom(field) do
    field in fields(slot)
  end

  def field_valid?(_, _), do: false

  @doc "Generation algo atom for a slot, or `nil` if unknown."
  def algo(slot) when is_atom(slot) do
    case Map.get(@slots, slot) do
      %{algo: a} -> a
      _ -> nil
    end
  end

  def algo(_), do: nil

  @doc "Consumer services for a slot, or `[]` if unknown."
  def consumers(slot) when is_atom(slot) do
    case Map.get(@slots, slot) do
      %{consumers: c} -> c
      _ -> []
    end
  end

  def consumers(_), do: []

  @doc "Storage modes the current codebase actually implements."
  def implemented_storage, do: @implemented_storage

  @doc "Storage modes recognized but not yet implemented (atom => layer tag)."
  def pending_storage, do: @pending_storage

  @doc "True if `mode` is any known storage atom."
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
