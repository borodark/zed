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
    [
      diff_datasets(ir),
      diff_apps(ir),
      diff_jails(ir),
      diff_clusters(ir)
    ]
    |> List.flatten()
    |> Enum.reject(fn d -> d.action == :noop end)
  end

  # Cluster diffs are unconditional :create entries — the artifact
  # write is idempotent (Zed.Cluster.Config.write!/3 atomic-renames
  # over any prior file), and we want the artifact rewritten on
  # every converge so members/cookie/topology stay in sync with the
  # IR. This trades a microsecond of disk write for the guarantee
  # that a stale config never lingers across a deploy.
  defp diff_clusters(%IR{clusters: clusters}) do
    Enum.map(clusters, fn node ->
      %__MODULE__{
        resource: node,
        action: :create,
        current: nil,
        desired: node.config,
        changes: [{:cluster_config, nil, node.id}]
      }
    end)
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
    apps
    |> Enum.map(fn node ->
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

  # --- Jails ---

  defp diff_jails(%IR{pool: pool, jails: jails}) do
    jails
    |> Enum.map(fn node ->
      ds = node.config[:dataset]
      full_ds = if ds, do: "#{pool}/#{ds}", else: nil

      # Check if jail is registered in ZFS properties
      current_jail =
        if full_ds && Dataset.exists?(full_ds) do
          case Property.get(full_ds, "jail") do
            {:ok, name} -> name
            :not_set -> nil
          end
        end

      jail_name = to_string(node.id)

      if current_jail == jail_name do
        %__MODULE__{
          resource: node,
          action: :noop,
          current: %{jail: current_jail},
          desired: node.config,
          changes: []
        }
      else
        %__MODULE__{
          resource: node,
          action: if(current_jail, do: :update, else: :create),
          current: %{jail: current_jail},
          desired: node.config,
          changes: [{:jail, current_jail, jail_name}]
        }
      end
    end)
  end
end
