defmodule Zed.Output do
  @moduledoc """
  CLI output formatting: tables, diffs, status displays.
  """

  @doc "Print a diff to stdout."
  def print_diff([]) do
    IO.puts("No changes needed — deployment is converged.")
  end

  def print_diff(diffs) do
    IO.puts("Changes needed:")
    IO.puts("")

    Enum.each(diffs, fn diff ->
      type = diff.resource.type
      id = diff.resource.id
      action = diff.action

      IO.puts("  #{action_symbol(action)} #{type}:#{id}")

      Enum.each(diff.changes, fn {prop, old, new} ->
        IO.puts("    #{prop}: #{inspect(old)} -> #{inspect(new)}")
      end)
    end)

    IO.puts("")
    IO.puts("#{length(diffs)} resource(s) to converge.")
  end

  @doc "Print a convergence plan to stdout."
  def print_plan(%Zed.Converge.Plan{steps: steps}) do
    IO.puts("Execution plan:")
    IO.puts("")

    Enum.with_index(steps, 1)
    |> Enum.each(fn {step, i} ->
      IO.puts("  #{i}. [#{step.type}] #{step.action} #{step.id}")

      if step.deps != [] do
        IO.puts("     depends on: #{Enum.join(step.deps, ", ")}")
      end
    end)

    IO.puts("")
    IO.puts("#{length(steps)} step(s) to execute.")
  end

  @doc "Print deployment status to stdout."
  def print_status(state) do
    IO.puts("Deployment Status")
    IO.puts("=================")
    IO.puts("")

    IO.puts("Datasets:")
    Enum.each(state.datasets, fn {id, ds} ->
      status = if ds.exists, do: "exists", else: "MISSING"
      IO.puts("  #{id}: #{status}")

      if ds.exists do
        IO.puts("    mountpoint: #{ds.mountpoint}")

        Enum.each(ds.properties, fn {k, v} ->
          IO.puts("    com.zed:#{k} = #{v}")
        end)
      end
    end)

    IO.puts("")
    IO.puts("Apps:")

    Enum.each(state.apps, fn {id, app} ->
      version = app.version || "(not deployed)"
      IO.puts("  #{id}: v#{version}")

      if app.deployed_at, do: IO.puts("    deployed: #{app.deployed_at}")
      if app.health, do: IO.puts("    health: #{app.health}")
      if app.node_name, do: IO.puts("    node: #{app.node_name}")
    end)
  end

  @doc "Print convergence result."
  def print_result({:ok, :no_changes}) do
    IO.puts("Already converged. No changes applied.")
  end

  def print_result({:ok, results}) do
    IO.puts("Converged successfully.")

    Enum.each(results, fn {step_id, status} ->
      IO.puts("  #{check_symbol(status)} #{step_id}")
    end)
  end

  def print_result({:dry_run, plan}) do
    IO.puts("DRY RUN — no changes applied.")
    print_plan(plan)
  end

  def print_result({:error, :step_failed, step, reason}) do
    IO.puts("FAILED at step: #{step.id}")
    IO.puts("  reason: #{inspect(reason)}")
    IO.puts("  Rolled back to pre-deploy snapshot.")
  end

  defp action_symbol(:create), do: "+"
  defp action_symbol(:update), do: "~"
  defp action_symbol(:noop), do: " "

  defp check_symbol(:ok), do: "ok"
  defp check_symbol(:would_execute), do: "--"
  defp check_symbol(:version_stamped), do: "ok"
  defp check_symbol(_), do: "??"
end
