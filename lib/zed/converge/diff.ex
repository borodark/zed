defmodule Zed.Converge.Diff do
  @moduledoc """
  Compare desired state (IR) against current state (ZFS properties).
  Returns a list of changes needed to converge.
  """

  alias Zed.ZFS.{Dataset, Property}
  alias Zed.IR

  defstruct [:resource, :action, :current, :desired, changes: []]

  @type t :: %__MODULE__{
          resource: Zed.IR.Node.t(),
          action: :create | :update | :noop,
          current: map() | nil,
          desired: map(),
          changes: [{atom(), term(), term()}]
        }

  @doc "Compute the diff between IR and current ZFS state."
  def compute(%IR{} = ir) do
    dataset_diffs = diff_datasets(ir)
    app_diffs = diff_apps(ir)

    (dataset_diffs ++ app_diffs)
    |> Enum.reject(fn d -> d.action == :noop end)
  end

  # --- Datasets ---

  defp diff_datasets(%IR{pool: pool, datasets: datasets}) do
    Enum.map(datasets, fn node ->
      full_path = "#{pool}/#{node.id}"

      if Dataset.exists?(full_path) do
        changes = diff_dataset_props(full_path, node.config)

        %__MODULE__{
          resource: node,
          action: if(changes == [], do: :noop, else: :update),
          current: current_dataset_state(full_path),
          desired: node.config,
          changes: changes
        }
      else
        %__MODULE__{
          resource: node,
          action: :create,
          current: nil,
          desired: node.config,
          changes: [{:exists, false, true}]
        }
      end
    end)
  end

  defp diff_dataset_props(full_path, config) do
    changes = []

    changes =
      if config[:mountpoint] do
        current_mp = Dataset.mountpoint(full_path)

        if current_mp != config[:mountpoint] do
          [{:mountpoint, current_mp, config[:mountpoint]} | changes]
        else
          changes
        end
      else
        changes
      end

    changes =
      if config[:compression] do
        case Dataset.get_property(full_path, "compression") do
          {:ok, current} ->
            desired = to_string(config[:compression])

            if current != desired do
              [{:compression, current, desired} | changes]
            else
              changes
            end

          _ ->
            changes
        end
      else
        changes
      end

    changes
  end

  defp current_dataset_state(full_path) do
    %{
      mountpoint: Dataset.mountpoint(full_path),
      properties: Property.get_all(full_path)
    }
  end

  # --- Apps ---

  defp diff_apps(%IR{pool: pool, apps: apps}) do
    Enum.map(apps, fn node ->
      ds = node.config[:dataset]
      full_ds = if ds, do: "#{pool}/#{ds}", else: nil

      current_version =
        if full_ds do
          case Property.get(full_ds, "version") do
            {:ok, v} -> v
            :not_set -> nil
          end
        end

      desired_version = node.config[:version]

      if current_version == desired_version do
        %__MODULE__{
          resource: node,
          action: :noop,
          current: %{version: current_version},
          desired: node.config,
          changes: []
        }
      else
        %__MODULE__{
          resource: node,
          action: if(current_version, do: :update, else: :create),
          current: %{version: current_version},
          desired: node.config,
          changes: [{:version, current_version, desired_version}]
        }
      end
    end)
  end
end
