defmodule Zed.Converge do
  @moduledoc """
  Convergence engine: diff → plan → apply → verify.

  The core loop that makes reality match the declared state.
  """

  alias Zed.Converge.{Diff, Plan, Executor}
  alias Zed.ZFS.Snapshot
  alias Zed.IR

  @doc "Run the full convergence loop."
  def run(%IR{} = ir, opts \\ []) do
    platform = Zed.Platform.Detect.current()
    dry_run = Keyword.get(opts, :dry_run, false)

    # Phase 1: Diff
    diff = Diff.compute(ir)

    if diff == [] do
      {:ok, :no_changes}
    else
      # Phase 2: Plan
      plan = Plan.from_diff(diff, dry_run: dry_run, pool: ir.pool)

      if dry_run do
        {:dry_run, plan}
      else
        # Pre-deploy snapshots
        :ok = take_pre_deploy_snapshots(ir)

        # Phase 3: Apply
        case Executor.run(plan, platform) do
          {:ok, results} ->
            # Phase 4: Verify
            stamp_deploy_properties(ir)
            {:ok, results}

          {:error, step, reason, _partial} ->
            rollback_pre_deploy(ir)
            {:error, :step_failed, step, reason}
        end
      end
    end
  end

  @doc "Rollback to a previous version or snapshot name."
  def rollback(%IR{} = ir, target) do
    platform = Zed.Platform.Detect.current()

    results =
      Enum.map(ir.apps, fn app ->
        ds = app.config[:dataset]
        full_ds = "#{ir.pool}/#{ds}"

        snapshot =
          case target do
            "@latest" ->
              snap = Snapshot.find_latest(full_ds)
              snap && snap.name

            version when is_binary(version) ->
              snap = Snapshot.find_latest(full_ds, "zed-deploy-#{version}")
              snap && snap.name
          end

        if snapshot do
          case Snapshot.rollback(snapshot) do
            {:ok, _} ->
              restart_app_service(app, platform)
              {:ok, app.id}

            {:error, msg, _code} ->
              {:error, {:rollback_failed, app.id, msg}}
          end
        else
          {:error, {:no_snapshot, app.id, target}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  # --- Private ---

  defp take_pre_deploy_snapshots(%IR{snapshot_config: %{before_deploy: true}} = ir) do
    Enum.each(ir.datasets, fn node ->
      full_path = "#{ir.pool}/#{node.id}"

      if Zed.ZFS.Dataset.exists?(full_path) do
        version = find_target_version(ir)
        Snapshot.create_deploy_snapshot(full_path, version)
      end
    end)

    :ok
  end

  defp take_pre_deploy_snapshots(_ir), do: :ok

  defp rollback_pre_deploy(%IR{} = ir) do
    platform = Zed.Platform.Detect.current()

    Enum.each(ir.datasets, fn node ->
      full_path = "#{ir.pool}/#{node.id}"
      snap = Snapshot.find_latest(full_path, "zed-deploy-")

      if snap do
        Snapshot.rollback(snap.name)
      end
    end)

    Enum.each(ir.apps, fn app ->
      restart_app_service(app, platform)
    end)
  end

  defp stamp_deploy_properties(%IR{} = ir) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each(ir.apps, fn app ->
      ds = app.config[:dataset]

      if ds do
        full_ds = "#{ir.pool}/#{ds}"

        # Look up any tarfs mount whose name matches the app's id or
        # release. Hash the tar to produce a content-addressed
        # fingerprint that travels with the dataset and survives
        # zfs send | zfs receive. This is what makes "what's
        # actually deployed" answerable from the artifact dataset
        # alone, without consulting an external store.
        {tar_path, fingerprint} = tar_fingerprint(ir, app)

        props = %{
          managed: "true",
          app: to_string(app.id),
          version: app.config[:version] || "unknown",
          deployed_at: ts,
          deployed_by: whoami()
        }

        props =
          props
          |> maybe_put_string(:tar_path, tar_path)
          |> maybe_put_string(:fingerprint, fingerprint)
          |> maybe_put_string(:built_at, app.config[:built_at])
          |> maybe_put_string(:built_by, app.config[:built_by])
          |> maybe_put_string(:git_sha, app.config[:git_sha])

        Zed.ZFS.Property.set_many(full_ds, props)
      end
    end)
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, to_string(value))

  # Return {tar_path, sha256_hex} for the tarfs mount that backs
  # this app, or {nil, nil} if there isn't one. Tarfs is the
  # universal artifact format for zed-managed apps; if the user
  # used a different mechanism (jail/release_dir/etc.) we just
  # skip these fields.
  defp tar_fingerprint(%IR{tarfs_mounts: mounts}, app) do
    mount =
      Enum.find(mounts, fn m ->
        m.id == app.id or m.config[:app] == app.id
      end) ||
      List.first(mounts)

    case mount do
      nil ->
        {nil, nil}

      %{config: %{tar_path: path}} ->
        case sha256_file(path) do
          {:ok, hex} -> {path, "sha256:" <> hex}
          {:error, _} -> {path, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp sha256_file(path) do
    with {:ok, bin} <- File.read(path) do
      {:ok, :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)}
    end
  end

  defp find_target_version(%IR{apps: [app | _]}) do
    app.config[:version] || "unknown"
  end

  defp find_target_version(_), do: "unknown"

  defp restart_app_service(app, platform) do
    service = to_string(app.config[:service] || app.id)
    platform.service_restart(service)
  end

  defp whoami do
    case System.cmd("whoami", []) do
      {name, 0} -> String.trim(name) <> "@" <> hostname()
      _ -> "unknown"
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end
end
