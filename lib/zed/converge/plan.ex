defmodule Zed.Converge.Plan do
  @moduledoc """
  Build an ordered execution plan from a diff.

  Steps are topologically sorted: datasets before apps,
  apps before services, snapshots before mutations.
  """

  alias Zed.Converge.{Diff, Step}

  defstruct steps: [], dry_run: false

  @type t :: %__MODULE__{
          steps: [Step.t()],
          dry_run: boolean()
        }

  @doc "Build an execution plan from diff entries."
  def from_diff(diff_entries, opts \\ []) do
    steps =
      diff_entries
      |> Enum.flat_map(&expand_to_steps/1)
      |> sort_by_type()

    %__MODULE__{
      steps: steps,
      dry_run: Keyword.get(opts, :dry_run, false)
    }
  end

  # --- Step Expansion ---

  defp expand_to_steps(%Diff{resource: %{type: :dataset} = node, action: :create}) do
    props =
      node.config
      |> Map.take([:mountpoint, :compression, :quota, :recordsize])
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.new()

    [
      %Step{
        id: "dataset:create:#{node.id}",
        type: :dataset,
        action: :create,
        args: %{path: node.id, properties: props}
      }
    ]
  end

  defp expand_to_steps(%Diff{resource: %{type: :dataset} = node, action: :update, changes: changes}) do
    Enum.map(changes, fn {prop, _old, new} ->
      %Step{
        id: "dataset:set:#{node.id}:#{prop}",
        type: :dataset,
        action: :update,
        args: %{path: node.id, property: to_string(prop), value: to_string(new)}
      }
    end)
  end

  defp expand_to_steps(%Diff{resource: %{type: :app} = node, action: action})
       when action in [:create, :update] do
    steps = []

    # Deploy the release
    steps = [
      %Step{
        id: "app:deploy:#{node.id}",
        type: :app,
        action: :create,
        args: %{
          app: node.id,
          version: node.config[:version],
          dataset: node.config[:dataset],
          release_path: node.config[:release_path],
          env_file: node.config[:env_file]
        },
        deps: if(node.config[:dataset], do: ["dataset:create:#{node.config[:dataset]}"], else: [])
      }
      | steps
    ]

    # Restart service
    steps = [
      %Step{
        id: "service:restart:#{node.id}",
        type: :service,
        action: :restart,
        args: %{service: node.config[:service] || to_string(node.id)},
        deps: ["app:deploy:#{node.id}"]
      }
      | steps
    ]

    Enum.reverse(steps)
  end

  defp expand_to_steps(_), do: []

  # Sort: datasets first, then apps, then services.
  defp sort_by_type(steps) do
    priority = %{dataset: 0, snapshot: 1, app: 2, service: 3}

    Enum.sort_by(steps, fn step ->
      Map.get(priority, step.type, 99)
    end)
  end
end
