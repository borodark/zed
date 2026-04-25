defmodule Zed.IR.Validate do
  @moduledoc """
  Compile-time validation passes for the deployment IR.
  Catches broken references and invalid configurations before
  anything touches disk.
  """

  alias Zed.IR
  alias Zed.Secrets.Catalog

  @doc "Validate the IR, raising on errors."
  def run!(%IR{} = ir) do
    check_pool(ir)
    check_dataset_refs(ir)
    check_jail_contains(ir)
    check_no_inline_secrets(ir)
    check_secret_refs(ir)
    check_cluster_cookies(ir)
    check_cluster_members(ir)
    ir
  end

  # Every IR must have a pool.
  defp check_pool(%IR{pool: nil}), do: raise(Zed.ValidationError, "deploy block requires a pool")
  defp check_pool(%IR{pool: p}) when is_binary(p), do: :ok
  defp check_pool(_), do: raise(Zed.ValidationError, "pool must be a string")

  # Every app must reference a dataset that exists in the IR.
  defp check_dataset_refs(%IR{} = ir) do
    known = MapSet.new(IR.dataset_ids(ir))

    Enum.each(ir.apps, fn app ->
      ds = app.config[:dataset]

      if ds && ds not in known do
        raise Zed.ValidationError,
              "app #{inspect(app.id)} references dataset #{inspect(ds)} which is not declared"
      end
    end)
  end

  # Every jail's `contains` must reference a declared app.
  defp check_jail_contains(%IR{} = ir) do
    known = MapSet.new(IR.app_ids(ir))

    Enum.each(ir.jails, fn jail ->
      contained = jail.config[:contains]

      if contained && contained not in known do
        raise Zed.ValidationError,
              "jail #{inspect(jail.id)} contains #{inspect(contained)} which is not a declared app"
      end
    end)
  end

  # Cookies must never be inline strings — only {:env, "VAR"}, {:file, path},
  # or a {:secret, ...} reference validated by `check_secret_refs/1`.
  defp check_no_inline_secrets(%IR{} = ir) do
    Enum.each(ir.apps, fn app ->
      cookie = app.config[:cookie]

      case cookie do
        nil -> :ok
        {:env, _} -> :ok
        {:file, _} -> :ok
        {:secret, _} -> :ok
        {:secret, _, _} -> :ok
        {:secret, _, _, _} -> :ok
        s when is_binary(s) ->
          raise Zed.ValidationError,
                "app #{inspect(app.id)} has an inline cookie string — use {:env, \"VAR\"}, {:file, path}, or {:secret, :slot} instead"
        s when is_atom(s) ->
          raise Zed.ValidationError,
                "app #{inspect(app.id)} has an inline cookie atom — use {:env, \"VAR\"}, {:file, path}, or {:secret, :slot} instead"
        _ -> :ok
      end
    end)
  end

  # Every {:secret, slot, field, opts} reference must name a known slot,
  # a valid field for that slot, and (if `storage:` is given) a legal
  # storage mode. Future storage modes recognized but not yet
  # implemented fail with a pointer to the layer that will ship them.
  defp check_secret_refs(%IR{} = ir) do
    Enum.each(ir.apps, fn app ->
      Enum.each(app.config, fn {config_key, value} ->
        case classify_secret_ref(value) do
          :not_a_secret_ref -> :ok
          {:secret_ref, slot, field, opts} ->
            validate_secret_ref!(slot, field, opts, app.id, config_key)
        end
      end)
    end)
  end

  defp classify_secret_ref({:secret, slot}), do: {:secret_ref, slot, :value, []}
  defp classify_secret_ref({:secret, slot, field}), do: {:secret_ref, slot, field, []}
  defp classify_secret_ref({:secret, slot, field, opts}) when is_list(opts),
    do: {:secret_ref, slot, field, opts}
  defp classify_secret_ref(_), do: :not_a_secret_ref

  defp validate_secret_ref!(slot, field, opts, app_id, config_key) do
    check_slot_known!(slot, app_id, config_key)
    check_field_valid!(slot, field, app_id, config_key)
    check_storage_mode!(Keyword.get(opts, :storage, :local_file), slot, app_id, config_key)
    :ok
  end

  defp check_slot_known!(slot, app_id, config_key) when is_atom(slot) do
    if Catalog.slot_known?(slot) do
      :ok
    else
      raise Zed.ValidationError,
            "app #{inspect(app_id)} #{inspect(config_key)}: unknown secret slot #{inspect(slot)} (known: #{inspect(Catalog.slots())})"
    end
  end

  defp check_slot_known!(slot, app_id, config_key) do
    raise Zed.ValidationError,
          "app #{inspect(app_id)} #{inspect(config_key)}: secret slot must be an atom, got #{inspect(slot)}"
  end

  defp check_field_valid!(slot, field, app_id, config_key) when is_atom(field) do
    if Catalog.field_valid?(slot, field) do
      :ok
    else
      raise Zed.ValidationError,
            "app #{inspect(app_id)} #{inspect(config_key)}: slot #{inspect(slot)} has no field #{inspect(field)} (valid fields: #{inspect(Catalog.fields(slot))})"
    end
  end

  defp check_field_valid!(_slot, field, app_id, config_key) do
    raise Zed.ValidationError,
          "app #{inspect(app_id)} #{inspect(config_key)}: secret field must be an atom, got #{inspect(field)}"
  end

  # Cluster cookies follow the same hygiene rule as app cookies — no
  # inline strings, no inline atoms. Same set of allowed shapes:
  # {:env, "VAR"}, {:file, path}, {:secret, slot[, field[, opts]]}.
  # The {:secret, ...} shape also gets the full Catalog walk via
  # check_secret_refs_in_clusters/1.
  defp check_cluster_cookies(%IR{} = ir) do
    Enum.each(ir.clusters, fn cluster ->
      cookie = cluster.config[:cookie]

      case cookie do
        nil -> :ok
        {:env, _} -> :ok
        {:file, _} -> :ok
        {:secret, slot} -> validate_secret_ref!(slot, :value, [], cluster.id, :cookie)
        {:secret, slot, field} -> validate_secret_ref!(slot, field, [], cluster.id, :cookie)
        {:secret, slot, field, opts} when is_list(opts) ->
          validate_secret_ref!(slot, field, opts, cluster.id, :cookie)
        s when is_binary(s) ->
          raise Zed.ValidationError,
                "cluster #{inspect(cluster.id)} has an inline cookie string — use {:env, \"VAR\"}, {:file, path}, or {:secret, :slot} instead"
        s when is_atom(s) ->
          raise Zed.ValidationError,
                "cluster #{inspect(cluster.id)} has an inline cookie atom — use {:env, \"VAR\"}, {:file, path}, or {:secret, :slot} instead"
        _ -> :ok
      end
    end)
  end

  # Cluster `members` is a list of node atoms shaped `:"name@host"`.
  # The host part is whatever — IP, dotted FQDN, mDNS, anything BEAM
  # accepts. We only check the @ separator and that the node name half
  # is non-empty, because the BEAM itself rejects malformed node names
  # at start_distribution time and that's the right place for the deep
  # check. Empty member list is allowed for now (cluster declared but
  # not yet populated; populated by a later iteration's discovery).
  defp check_cluster_members(%IR{} = ir) do
    Enum.each(ir.clusters, fn cluster ->
      members = cluster.config[:members] || []

      cond do
        not is_list(members) ->
          raise Zed.ValidationError,
                "cluster #{inspect(cluster.id)} :members must be a list, got #{inspect(members)}"

        true ->
          Enum.each(members, fn m ->
            unless valid_node_atom?(m) do
              raise Zed.ValidationError,
                    "cluster #{inspect(cluster.id)} member #{inspect(m)} is not a valid node atom (expected :\"name@host\")"
            end
          end)
      end
    end)
  end

  defp valid_node_atom?(m) when is_atom(m) do
    m
    |> Atom.to_string()
    |> String.split("@", parts: 2)
    |> case do
      [name, host] when name != "" and host != "" -> true
      _ -> false
    end
  end

  defp valid_node_atom?(_), do: false

  defp check_storage_mode!(mode, slot, app_id, config_key) do
    cond do
      Catalog.storage_implemented?(mode) ->
        :ok

      Catalog.storage_known?(mode) ->
        layer = Catalog.storage_pending_layer(mode)
        raise Zed.ValidationError,
              "app #{inspect(app_id)} #{inspect(config_key)} slot #{inspect(slot)}: storage mode #{inspect(mode)} is not yet implemented, pending Layer #{layer}"

      true ->
        raise Zed.ValidationError,
              "app #{inspect(app_id)} #{inspect(config_key)} slot #{inspect(slot)}: unknown storage mode #{inspect(mode)} (implemented: #{inspect(Catalog.implemented_storage())})"
    end
  end
end

defmodule Zed.ValidationError do
  defexception [:message]

  @impl true
  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
  def exception(opts), do: %__MODULE__{message: opts[:message] || "validation failed"}
end
