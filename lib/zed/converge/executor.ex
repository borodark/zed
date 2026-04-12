defmodule Zed.Converge.Executor do
  @moduledoc """
  Execute a convergence plan step by step.

  If any step fails, returns immediately with the failure
  so the caller can trigger rollback.
  """

  alias Zed.Converge.{Plan, Step}
  alias Zed.ZFS.{Dataset, Property}

  @doc "Execute a plan. Returns {:ok, results} or {:error, step, reason, partial}."
  def run(%Plan{steps: steps, dry_run: true}, _platform) do
    results = Enum.map(steps, fn step -> {step.id, :would_execute} end)
    {:ok, results}
  end

  def run(%Plan{steps: steps}, platform) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, results} ->
      case execute_step(step, platform) do
        :ok ->
          {:cont, {:ok, [{step.id, :ok} | results]}}

        {:ok, detail} ->
          {:cont, {:ok, [{step.id, detail} | results]}}

        {:error, reason} ->
          {:halt, {:error, step, reason, results}}
      end
    end)
  end

  # --- Step Execution ---

  defp execute_step(%Step{type: :dataset, action: :create, args: args}, _platform) do
    # Pool prefix is added by the convergence engine before we get here.
    # The args.path is relative to pool, but we need the full path.
    # For now, we trust the path includes the pool.
    pool_path = args[:pool_path] || args.path

    case Dataset.create(pool_path, args.properties) do
      {:ok, _} ->
        Property.set(pool_path, "managed", "true")
        :ok

      {:error, msg, _code} ->
        {:error, {:dataset_create_failed, pool_path, msg}}
    end
  end

  defp execute_step(%Step{type: :dataset, action: :update, args: args}, _platform) do
    pool_path = args[:pool_path] || args.path

    case Dataset.set_property(pool_path, args.property, args.value) do
      {:ok, _} -> :ok
      {:error, msg, _} -> {:error, {:dataset_set_failed, pool_path, args.property, msg}}
    end
  end

  defp execute_step(%Step{type: :app, action: :create, args: args}, _platform) do
    # In Phase 1, we just set the version property.
    # Full release unpack comes when Zed.Beam.Release is wired up.
    ds = args[:dataset]

    if ds do
      pool_path = args[:pool_path] || ds
      Property.set(pool_path, "version", to_string(args.version))
      Property.set(pool_path, "app", to_string(args.app))
      {:ok, :version_stamped}
    else
      :ok
    end
  end

  defp execute_step(%Step{type: :service, action: :restart, args: args}, platform) do
    case platform.service_restart(args.service) do
      :ok -> :ok
      {:error, reason} -> {:error, {:service_restart_failed, args.service, reason}}
    end
  end

  defp execute_step(%Step{} = step, _platform) do
    {:error, {:unknown_step, step.type, step.action}}
  end
end
