defmodule Zed.IR.Validate do
  @moduledoc """
  Compile-time validation passes for the deployment IR.
  Catches broken references and invalid configurations before
  anything touches disk.
  """

  alias Zed.IR

  @doc "Validate the IR, raising on errors."
  def run!(%IR{} = ir) do
    check_pool(ir)
    check_dataset_refs(ir)
    check_jail_contains(ir)
    check_no_inline_secrets(ir)
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

  # Cookies must never be inline strings — only {:env, "VAR"} or {:file, path}.
  defp check_no_inline_secrets(%IR{} = ir) do
    Enum.each(ir.apps, fn app ->
      cookie = app.config[:cookie]

      case cookie do
        nil -> :ok
        {:env, _} -> :ok
        {:file, _} -> :ok
        s when is_binary(s) ->
          raise Zed.ValidationError,
                "app #{inspect(app.id)} has an inline cookie string — use {:env, \"VAR\"} instead"
        s when is_atom(s) ->
          raise Zed.ValidationError,
                "app #{inspect(app.id)} has an inline cookie atom — use {:env, \"VAR\"} instead"
        _ -> :ok
      end
    end)
  end
end

defmodule Zed.ValidationError do
  defexception [:message]

  @impl true
  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
  def exception(opts), do: %__MODULE__{message: opts[:message] || "validation failed"}
end
