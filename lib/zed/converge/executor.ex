defmodule Zed.Converge.Executor do
  @moduledoc """
  Execute a convergence plan step by step.

  Handles `:dataset`, `:app`, `:service`, and `:jail` step types with
  real ZFS/platform operations. Jail sub-steps (`:jail_pkg`,
  `:jail_mount`, `:jail_svc`) shell out through
  `Zed.Platform.Bastille`.

  If any step fails, returns immediately with the failure
  so the caller can trigger rollback.
  """

  alias Zed.Converge.{Plan, Step}
  alias Zed.ZFS.{Dataset, Property}
  alias Zed.Beam.Release
  alias Zed.Platform.Bastille

  @doc "Execute a plan. Returns {:ok, results} or {:error, step, reason, partial}."
  def run(%Plan{steps: steps, dry_run: true}, _platform) do
    steps
    |> Enum.map(fn step -> {step.id, :would_execute} end)
    |> then(&{:ok, &1})
  end

  def run(%Plan{steps: steps}, platform) do
    steps
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, results} ->
      case execute_step(step, platform) do
        :ok -> {:cont, {:ok, [{step.id, :ok} | results]}}
        {:ok, detail} -> {:cont, {:ok, [{step.id, detail} | results]}}
        {:error, reason} -> {:halt, {:error, step, reason, results}}
      end
    end)
  end

  # --- Step Execution (grouped by pattern) ---

  defp execute_step(%Step{type: :dataset, action: :create, args: args}, _platform) do
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
    pool_path = args[:pool_path] || args[:dataset]
    version = args.version |> to_string()

    with {:ok, deploy_detail} <- deploy_release(args, version),
         :ok <- stamp_app_properties(pool_path, args, version) do
      {:ok, deploy_detail}
    end
  end

  defp execute_step(%Step{type: :service, action: :install, args: args}, platform) do
    config = %{
      command: Path.join([args.mountpoint, "current", "bin", args.service]),
      user: args[:user] || args.service,
      env_file: args[:env_file]
    }

    case platform.service_install(args.service, config) do
      :ok -> :ok
      {:error, reason} -> {:error, {:service_install_failed, args.service, reason}}
    end
  end

  defp execute_step(%Step{type: :service, action: :restart, args: args}, platform) do
    case platform.service_restart(args.service) do
      :ok -> :ok
      {:error, reason} -> {:error, {:service_restart_failed, args.service, reason}}
    end
  end

  defp execute_step(%Step{type: :jail, action: :install, args: args}, platform) do
    config = %{
      path: args.path,
      hostname: args.hostname,
      ip4: args.ip4,
      ip6: args.ip6,
      vnet: args.vnet,
      release: args[:release],
      jail_params: args[:jail_params] || []
    }

    jail_name = args.jail |> to_string()

    case platform.jail_install(jail_name, config) do
      :ok -> :ok
      {:error, reason} -> {:error, {:jail_install_failed, jail_name, reason}}
    end
  end

  defp execute_step(%Step{type: :jail, action: :create, args: args}, platform) do
    jail_name = args.jail |> to_string()

    with :ok <- create_jail(jail_name, platform),
         :ok <- stamp_jail_properties(args) do
      {:ok, :jail_created}
    end
  end

  # --- Jail sub-steps ---

  # pkg install -y runs inside the jail via `bastille cmd`. pkg itself
  # is idempotent — already-installed packages are a no-op that still
  # exits 0.
  defp execute_step(%Step{type: :jail_pkg, action: :install, args: args}, _platform) do
    jail = to_string(args.jail)
    packages = Enum.map(args.packages, &to_string/1)

    case Bastille.cmd(jail, ["pkg", "install", "-y" | packages]) do
      {:ok, _output} -> {:ok, {:jail_pkg_installed, jail, packages}}
      {:error, reason} -> {:error, {:jail_pkg_failed, jail, packages, reason}}
    end
  end

  # Nullfs mount is not idempotent — probe the jail's own mount table
  # first and short-circuit if `jail_path` is already the target of a
  # mount. Otherwise call `bastille mount`.
  defp execute_step(%Step{type: :jail_mount, action: :create, args: args}, _platform) do
    jail = to_string(args.jail)
    host_path = to_string(args.host_path)
    jail_path = to_string(args.jail_path)
    mode = args[:mode] |> mode_to_string()

    case jail_mount_present?(jail, jail_path) do
      true ->
        {:ok, {:jail_mount_already_present, jail, jail_path}}

      false ->
        case Bastille.mount(jail, host_path, jail_path, mode: mode) do
          :ok -> {:ok, {:jail_mount_created, jail, host_path, jail_path}}
          {:error, reason} -> {:error, {:jail_mount_failed, jail, jail_path, reason}}
        end
    end
  end

  # Deploy a BEAM release tarball into a jail's rootfs. The
  # `mount_in_jail` is the app's installation path FROM INSIDE the
  # jail (e.g. "/opt/myapp"); the host-side write target is
  # <jails_dir>/<jail>/root<mount_in_jail>. Uses Zed.Beam.Release
  # which extracts under mountpoint/releases/<version>/ and points a
  # `current` symlink at it — same layout the host-side :app step
  # produces, just inside the jail's namespace.
  defp execute_step(%Step{type: :jail_app, action: :deploy, args: args}, _platform) do
    jail = to_string(args.jail)
    version = args.version |> to_string()
    release_path = args[:release_path]

    if is_nil(release_path) or release_path == "" do
      {:ok, {:jail_app_no_tarball, jail, args.app}}
    else
      host_mountpoint = "#{Bastille.jails_dir()}/#{jail}/root#{args.mount_in_jail}"

      with :ok <- File.mkdir_p(host_mountpoint),
           {:ok, version_dir} <- Release.deploy(release_path, version, host_mountpoint),
           :ok <- write_jail_env_file(jail, args) do
        {:ok, {:jail_app_deployed, jail, args.app, version_dir}}
      else
        {:error, {tag, _, _} = reason} when tag in [:jail_env_file_failed] ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:jail_app_deploy_failed, jail, args.app, reason}}
      end
    end
  end

  # Compose RELEASE_COOKIE + RELEASE_NODE into an env file inside the
  # jail's rootfs. The rc.d script Zed writes for a contained app
  # sources this file before invoking the release, so mix releases
  # boot with a distributed node name and shared cookie without any
  # runtime magic.
  #
  # No-op when either cookie or node_name is nil — the DSL allows
  # host-side apps to omit these; contained apps typically have both
  # (plan defaults env_file to /var/db/zed/<app>.env for contained
  # apps and the DSL validator requires a non-inline cookie shape).
  defp write_jail_env_file(_jail, %{cookie: nil}), do: :ok
  defp write_jail_env_file(_jail, %{node_name: nil}), do: :ok

  defp write_jail_env_file(jail, args) do
    env_file = args[:env_file]

    if is_nil(env_file) do
      :ok
    else
      case Zed.Beam.Env.resolve_cookie(args.cookie) do
        {:ok, cookie_value} ->
          content = Zed.Beam.Env.compose_env_file(args.node_name, cookie_value)
          host_path = "#{Bastille.jails_dir()}/#{jail}/root#{env_file}"
          write_env_file_idempotent(jail, env_file, host_path, content)

        {:error, reason} ->
          {:error, {:jail_env_file_failed, jail, {:cookie_resolve_failed, reason}}}
      end
    end
  end

  defp write_env_file_idempotent(jail, env_file, host_path, content) do
    case File.read(host_path) do
      {:ok, ^content} ->
        :ok

      _ ->
        with :ok <- File.mkdir_p(Path.dirname(host_path)),
             :ok <- File.write(host_path, content),
             :ok <- File.chmod(host_path, 0o400) do
          :ok
        else
          {:error, reason} -> {:error, {:jail_env_file_failed, jail, {env_file, reason}}}
        end
    end
  end

  # Write an rc(8) service script inside the jail rootfs so Path B's
  # :jail_svc :start (which shells to `bastille cmd <jail> sysrc +
  # service start`) has something to enable and start. The generated
  # script uses the release's foreground/daemon runner at
  # <mount_in_jail>/current/bin/<service>. Idempotent via content
  # match. Env file at `env_file` is sourced by the rc.d script if
  # present so cookies + node names flow through without shell
  # wrapping at the DSL layer.
  defp execute_step(%Step{type: :jail_service, action: :install, args: args}, _platform) do
    jail = to_string(args.jail)
    service = to_string(args.service)
    mount_in_jail = args.mount_in_jail
    # Do NOT default user to service name — plan intentionally passes
    # nil when the DSL didn't declare `user`, so rc.subr runs the
    # command as root. Falling back to service here re-introduces the
    # `su: unknown login: <service>` failure that d90c105 was meant
    # to fix.
    user = args[:user]
    env_file = args[:env_file]

    rc_path =
      "#{Bastille.jails_dir()}/#{jail}/root/usr/local/etc/rc.d/#{service}"

    content = render_jail_rc_script(service, mount_in_jail, user, env_file)

    case File.read(rc_path) do
      {:ok, ^content} ->
        {:ok, {:jail_service_already_current, jail, service}}

      _ ->
        with :ok <- File.mkdir_p(Path.dirname(rc_path)),
             :ok <- File.write(rc_path, content),
             :ok <- File.chmod(rc_path, 0o755) do
          {:ok, {:jail_service_installed, jail, service}}
        else
          {:error, reason} ->
            {:error, {:jail_service_install_failed, jail, service, reason}}
        end
    end
  end

  # Probe a jail-contained app for reachability after start. Runs from
  # the host's network namespace and dials the jail's declared IP via
  # bastille0. Failure surfaces as :jail_health_failed with the last
  # observed reason and the number of attempts made.
  defp execute_step(%Step{type: :jail_health, action: :probe, args: args}, _platform) do
    jail = to_string(args.jail)
    app = args.app
    type = args.probe_type
    opts = args.opts || %{}
    attempts = Map.get(opts, :attempts, 5)
    interval_ms = Map.get(opts, :interval, 2000)

    case retry_probe(type, opts, attempts, interval_ms, nil) do
      :ok -> {:ok, {:jail_health_ok, jail, app, type}}
      {:error, {n, reason}} -> {:error, {:jail_health_failed, jail, app, type, n, reason}}
    end
  end

  # Run the setup block's ops sequentially, gated on a content hash
  # so re-converge is a no-op when the block hasn't changed. Hash is
  # stored at <jails_dir>/<jail>/zed-setup.hash (plain hex).
  defp execute_step(%Step{type: :jail_setup, action: :run, args: args}, _platform) do
    jail = to_string(args.jail)
    ops = args.ops || []
    hash = setup_ops_hash(ops)
    hash_path = "#{Bastille.jails_dir()}/#{jail}/zed-setup.hash"

    case File.read(hash_path) do
      {:ok, ^hash} ->
        {:ok, {:jail_setup_already_current, jail}}

      _ ->
        case run_setup_ops(jail, ops) do
          :ok ->
            with :ok <- File.mkdir_p(Path.dirname(hash_path)),
                 :ok <- File.write(hash_path, hash) do
              {:ok, {:jail_setup_ran, jail, length(ops)}}
            else
              {:error, reason} ->
                {:error, {:jail_setup_hash_write_failed, jail, reason}}
            end

          {:error, reason} ->
            {:error, {:jail_setup_failed, jail, reason}}
        end
    end
  end

  # Write a file into the jail's rootfs from the host side. Bastille's
  # rootfs lives at <jails_dir>/<name>/root, so the jail-visible path
  # <p> maps to <jails_dir>/<name>/root<p> on the host. Idempotent:
  # skip the write if on-disk content already matches. Applies mode if
  # provided.
  defp execute_step(%Step{type: :jail_file, action: :create, args: args}, _platform) do
    jail = to_string(args.jail)
    jail_path = to_string(args.path)
    content = args.content || ""
    mode = args[:mode]

    # Content MUST be a binary. Historical trap: `content: @foo` inside
    # a DSL block used to get captured as an AST tuple and land here as
    # non-binary — File.write then errored with :badarg, with no clue
    # pointing at the DSL author. Reject early with a message that
    # names the DSL source of the problem. The DSL now unquotes @attr
    # refs so this path shouldn't trigger from correct usage; kept as
    # defense in depth for future regressions.
    if not is_binary(content) do
      {:error, {:jail_file_invalid_content, jail, jail_path, content}}
    else
      host_path = "#{Bastille.jails_dir()}/#{jail}/root#{jail_path}"

      case File.read(host_path) do
        {:ok, ^content} ->
          {:ok, {:jail_file_already_current, jail, jail_path}}

        _ ->
          with :ok <- File.mkdir_p(Path.dirname(host_path)),
               :ok <- File.write(host_path, content),
               :ok <- maybe_chmod(host_path, mode) do
            {:ok, {:jail_file_created, jail, jail_path}}
          else
            {:error, reason} -> {:error, {:jail_file_failed, jail, jail_path, reason}}
          end
      end
    end
  end

  # sysrc <svc>_enable=YES, then service <svc> start. Both run inside
  # the jail via `bastille cmd`. sysrc is idempotent. Service start is
  # gated on a status probe so re-converge is a no-op.
  defp execute_step(%Step{type: :jail_svc, action: :start, args: args}, _platform) do
    jail = to_string(args.jail)
    service = to_string(args.service)

    with :ok <- enable_service(jail, service),
         {:ok, outcome} <- start_service_if_needed(jail, service) do
      {:ok, {outcome, jail, service}}
    end
  end

  # Tarfs mount: idempotent.  If the requested mountpoint is already
  # bound to the requested tar, no-op.  Otherwise call
  # `doas mount -t tarfs <tar> <mount>`.  The kmod must be loaded
  # (host setup; persist via tarfs_load=YES in /boot/loader.conf).
  defp execute_step(%Step{type: :tarfs, action: :mount, args: args}, _platform) do
    case tarfs_mount_status(args.mount) do
      {:ok, src} when src == args.tar_path ->
        {:ok, {:tarfs_already_mounted, args.mount}}

      {:ok, other_src} ->
        {:error, {:tarfs_mount_conflict, args.mount, other_src}}

      :not_mounted ->
        case System.cmd("doas", ["mount", "-t", "tarfs", args.tar_path, args.mount],
               stderr_to_stdout: true
             ) do
          {_out, 0} -> {:ok, {:tarfs_mounted, args.mount}}
          {out, code} -> {:error, {:tarfs_mount_failed, args.mount, String.trim(out), code}}
        end
    end
  end

  # File write: idempotent.  If on-disk content matches, no-op;
  # otherwise rewrite and apply mode if specified.  Owner/group
  # changes are out of scope for now — assume parent dataset is
  # already chown'd to the right user.
  defp execute_step(%Step{type: :file, action: :write, args: args}, _platform) do
    desired = args.content

    current =
      case File.read(args.path) do
        {:ok, c} -> c
        _ -> nil
      end

    cond do
      current == desired ->
        {:ok, {:file_already_current, args.path}}

      true ->
        path = args.path
        File.mkdir_p!(Path.dirname(path))

        case File.write(path, desired) do
          :ok ->
            if args.mode, do: File.chmod!(path, args.mode)
            {:ok, {:file_written, path}}

          {:error, reason} ->
            {:error, {:file_write_failed, path, reason}}
        end
    end
  end

  # Service run: idempotent.  alive_check (currently only :epmd) lets
  # the executor short-circuit if the service is already up.  When
  # spawning, the env file (sourced via `set -a`-style shell wrapping)
  # provides RELEASE_COOKIE / RELEASE_NODE / app-specific env vars.
  # The command itself is expected to background-fork (mix release's
  # `daemon` mode does this); the executor doesn't tail it.
  defp execute_step(%Step{type: :service_run, action: :start, args: args}, _platform) do
    case service_run_alive?(args[:alive_check]) do
      true ->
        {:ok, {:service_already_running, args.name}}

      false ->
        cmd = args.command
        cmd_args = args.args || []
        cd = args[:cd] || "."
        env_file = args[:env_file]

        env = parse_env_file(env_file)

        case System.cmd(cmd, cmd_args, cd: cd, env: env, stderr_to_stdout: true) do
          {_out, 0} -> {:ok, {:service_started, args.name}}
          {out, code} -> {:error, {:service_run_failed, args.name, String.trim(out), code}}
        end
    end
  end

  # Cluster artifact write — touches the host filesystem under
  # <base>/zed/cluster/<id>.config. Synthesises a one-cluster IR
  # to feed the existing Cluster.Config.write!/3 helper instead of
  # duplicating its formatting logic.
  defp execute_step(%Step{type: :cluster_config, action: :create, args: args}, _platform) do
    fake_ir = %Zed.IR{
      name: :__step__,
      pool: nil,
      datasets: [],
      apps: [],
      jails: [],
      zones: [],
      clusters: [
        %Zed.IR.Node{
          id: args.cluster_id,
          type: :cluster,
          config: %{members: args.members},
          deps: []
        }
      ],
      snapshot_config: %{}
    }

    {:ok, [path]} = Zed.Cluster.Config.write!(fake_ir, args.base_mountpoint)
    {:ok, {:cluster_config_written, path}}
  end

  defp execute_step(%Step{} = step, _platform) do
    {:error, {:unknown_step, step.type, step.action}}
  end

  # --- Release Deployment Helpers ---

  defp deploy_release(%{release_path: path, mountpoint: mp}, version)
       when is_binary(path) and is_binary(mp) do
    case Release.deploy(path, version, mp) do
      {:ok, version_dir} -> {:ok, {:deployed, version_dir}}
      {:error, reason} -> {:error, {:release_deploy_failed, reason}}
    end
  end

  defp deploy_release(_args, _version), do: {:ok, :no_tarball}

  # --- Property Stamping Helpers ---

  defp stamp_app_properties(nil, _args, _version), do: :ok

  defp stamp_app_properties(pool_path, args, version) do
    pool_path |> Property.set("version", version)
    pool_path |> Property.set("app", args.app |> to_string())
    args[:node_name] |> maybe_set_property(pool_path, "node_name")
    :ok
  end

  defp maybe_set_property(nil, _pool_path, _key), do: :ok
  defp maybe_set_property(value, pool_path, key), do: Property.set(pool_path, key, to_string(value))

  # --- Jail Helpers ---

  defp create_jail(jail_name, platform) do
    case platform.jail_create(jail_name, %{}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:jail_create_failed, jail_name, reason}}
    end
  end

  # alive_check helpers for :service_run.  Currently only :epmd
  # (look up a registered short-name node).
  defp service_run_alive?(nil), do: false

  defp service_run_alive?({:epmd, sname}) do
    case System.cmd("epmd", ["-names"], stderr_to_stdout: true) do
      {out, 0} -> Regex.match?(~r/^name #{Regex.escape(sname)} /m, out)
      _ -> false
    end
  end

  # Parse a "VAR=value\n…" env file into the [{"VAR", "value"}, …]
  # shape System.cmd/3 wants.  Skips blank lines and shell comments.
  defp parse_env_file(nil), do: []

  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reject(fn line ->
          line == "" or String.starts_with?(String.trim(line), "#")
        end)
        |> Enum.map(fn line ->
          [k, v] = String.split(line, "=", parts: 2)
          {String.trim(k), v}
        end)

      _ ->
        []
    end
  end

  # Parse `mount` output to find the source for a given mountpoint.
  # Returns `{:ok, source}` when mounted, `:not_mounted` otherwise.
  defp tarfs_mount_status(mountpoint) do
    case System.cmd("mount", [], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.find_value(:not_mounted, fn line ->
          case Regex.run(~r/^(\S+) on (\S+) \(tarfs/, line) do
            [_, src, ^mountpoint] -> {:ok, src}
            _ -> nil
          end
        end)

      _ ->
        :not_mounted
    end
  end

  # Bastille nullfs-mounts the host path onto
  # <jails_dir>/<jail>/root<jail_path> from the host's mount namespace.
  # The jail's own mount(8) doesn't see this (mount output inside the
  # jail is filtered), so probe from the host side instead.
  defp jail_mount_present?(jail, jail_path) do
    host_mountpoint = "#{Bastille.jails_dir()}/#{jail}/root#{jail_path}"

    case System.cmd("mount", [], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, " on " <> host_mountpoint <> " (")
      _ -> false
    end
  end

  defp mode_to_string(nil), do: "ro"
  defp mode_to_string(:ro), do: "ro"
  defp mode_to_string(:rw), do: "rw"
  defp mode_to_string(bin) when is_binary(bin), do: bin

  defp maybe_chmod(_path, nil), do: :ok
  defp maybe_chmod(path, mode) when is_integer(mode), do: File.chmod(path, mode)

  # --- Health probe primitives ---

  defp retry_probe(_type, _opts, 0, _interval, last), do: {:error, {0, last}}

  defp retry_probe(type, opts, attempts_left, interval, _prev) do
    case probe_once(type, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        if attempts_left > 1, do: :timer.sleep(interval)
        retry_probe(type, opts, attempts_left - 1, interval, reason)
    end
  end

  # :tcp — dial host:port, close on success. Cheapest useful signal:
  # BEAM node's epmd (4369), a phoenix endpoint, or any listener the
  # service brought up.
  defp probe_once(:tcp, opts) do
    host = opts |> Map.get(:host) |> to_charlist_if_binary()
    port = Map.get(opts, :port)
    timeout = Map.get(opts, :timeout, 3000)

    case :gen_tcp.connect(host, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, {:tcp_connect_failed, reason}}
    end
  end

  # :http — GET the URL, compare status to opts[:expect] (default 200).
  # Uses :httpc which needs :inets started; extra_applications lists it.
  defp probe_once(:http, opts) do
    url = opts |> Map.get(:url) |> to_charlist_if_binary()
    expect = Map.get(opts, :expect, 200)
    timeout = Map.get(opts, :timeout, 3000)

    request = {url, []}
    http_opts = [timeout: timeout, connect_timeout: timeout]

    case :httpc.request(:get, request, http_opts, []) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status == expect ->
        :ok

      {:ok, {{_v, status, _r}, _h, _b}} ->
        {:error, {:http_status_mismatch, expect: expect, got: status}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  # :beam_ping — distributed-Erlang connect probe. Sets the cookie
  # against the target node (Erlang looks up cookie by target-node
  # atom) and calls :net_adm.ping/1. Success = :pong, failure = :pang.
  #
  # Requires the probing BEAM to be distributed. If it isn't, we
  # transiently start distribution with a random short-name so we can
  # send disterl traffic; this side effect only affects the current
  # BEAM run.
  defp probe_once(:beam_ping, opts) do
    node = Map.get(opts, :node)
    cookie_ref = Map.get(opts, :cookie)

    with :ok <- ensure_distribution_started(node),
         {:ok, cookie} <- resolve_probe_cookie(cookie_ref),
         :ok <- set_cookie_if_present(node, cookie) do
      case :net_adm.ping(node) do
        :pong -> :ok
        :pang -> {:error, {:beam_ping_pang, node}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe_once(other, _opts), do: {:error, {:unsupported_probe_type, other}}

  defp ensure_distribution_started(target_node) do
    case Node.self() do
      :nonode@nohost ->
        # Match the target's name mode. If target hostname contains
        # a dot (FQDN or IP), use :longnames — otherwise the ping
        # fails with "Hostname X is illegal" regardless of network.
        mode = detect_name_mode(target_node)
        host = local_host_for(mode)
        name = :"zed_probe_#{System.unique_integer([:positive])}@#{host}"

        case Node.start(name, mode) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, {:disterl_start_failed, reason}}
        end

      _ ->
        :ok
    end
  end

  # Longname = hostname part has a dot (typical for FQDN or IP address).
  # Shortname = bare word. Erlang's own :net_kernel makes this
  # distinction and refuses cross-mode ping.
  defp detect_name_mode(node_atom) do
    case node_atom |> Atom.to_string() |> String.split("@", parts: 2) do
      [_name, host] ->
        if String.contains?(host, "."), do: :longnames, else: :shortnames

      _ ->
        :shortnames
    end
  end

  defp local_host_for(:shortnames), do: hostname_short()
  defp local_host_for(:longnames), do: hostname_long()

  defp hostname_short do
    case :inet.gethostname() do
      {:ok, h} -> to_string(h)
      _ -> "localhost"
    end
  end

  # Use 127.0.0.1 as the longname host — always dotted, always
  # routable. Ties us to loopback but that's fine for the probe;
  # target-side routes back over the real interface.
  defp hostname_long, do: "127.0.0.1"

  # Accept either an already-resolved binary or a Zed.Beam.Env
  # cookie ref. Same shapes as :jail_app :deploy so operators pass
  # the same value in both places.
  defp resolve_probe_cookie(nil), do: {:ok, nil}
  defp resolve_probe_cookie(bin) when is_binary(bin), do: {:ok, bin}

  defp resolve_probe_cookie(ref) do
    case Zed.Beam.Env.resolve_cookie(ref) do
      {:ok, v} -> {:ok, v}
      {:error, reason} -> {:error, {:probe_cookie_resolve_failed, reason}}
    end
  end

  defp set_cookie_if_present(_node, nil), do: :ok

  defp set_cookie_if_present(node, cookie) when is_binary(cookie) do
    Node.set_cookie(node, String.to_atom(cookie))
    :ok
  end

  defp to_charlist_if_binary(v) when is_binary(v), do: String.to_charlist(v)
  defp to_charlist_if_binary(v), do: v

  # Minimal FreeBSD rc(8) script for a mix-release BEAM app running
  # inside a jail. Delegates to the release's `daemon` runner (mix
  # release's built-in). Env file is sourced if present so
  # RELEASE_COOKIE / RELEASE_NODE flow through.
  #
  # `user` is optional — when nil, no _user directive is emitted and
  # rc.subr runs the command as root. Per-user separation inside a
  # jail is opt-in via DSL; the security boundary is the jail itself.
  defp render_jail_rc_script(service, mount_in_jail, user, env_file) do
    env_line =
      case env_file do
        nil ->
          ""

        path ->
          # `set -a` auto-exports every var assigned during the source,
          # so mix release's bin/<app> child inherits RELEASE_NODE,
          # RELEASE_COOKIE, etc. Zed.Beam.Env writes `export` already
          # but this belt-and-suspenders handles env files a user
          # brings in from elsewhere.
          "\n[ -r #{path} ] && { set -a; . #{path}; set +a; }"
      end

    user_line =
      case user do
        nil -> ""
        u -> "\n: ${#{service}_user:=\"#{u}\"}"
      end

    """
    #!/bin/sh
    #
    # PROVIDE: #{service}
    # REQUIRE: DAEMON
    # KEYWORD: shutdown
    #
    # Generated by Zed — do not edit manually.

    . /etc/rc.subr

    name="#{service}"
    rcvar="#{service}_enable"
    load_rc_config $name

    : ${#{service}_enable:="NO"}#{user_line}

    command="#{mount_in_jail}/current/bin/#{service}"
    command_args="daemon"
    pidfile="/var/run/#{service}.pid"#{env_line}

    run_rc_command "$1"
    """
  end

  # SHA-256 over the deterministic term encoding of the ops list —
  # any change (order, args, options) invalidates the hash and
  # triggers a re-run.
  defp setup_ops_hash(ops) do
    :crypto.hash(:sha256, :erlang.term_to_binary(ops))
    |> Base.encode16(case: :lower)
  end

  defp run_setup_ops(_jail, []), do: :ok

  defp run_setup_ops(jail, [op | rest]) do
    case run_setup_op(jail, op) do
      :ok -> run_setup_ops(jail, rest)
      {:error, reason} -> {:error, {:op_failed, op, reason}}
    end
  end

  # cmd runs inside the jail via `sh -c` so shell syntax (pipes,
  # redirects, quoting) works exactly as the operator wrote it.
  defp run_setup_op(jail, {:cmd, cmd_str}) when is_binary(cmd_str) do
    case Bastille.cmd(jail, ["sh", "-c", cmd_str]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # file ops write from the host side into <jails_dir>/<jail>/root<path>
  # — same pattern as :jail_file, no shell escaping inside the jail.
  defp run_setup_op(jail, {:file, path, opts}) do
    host_path = "#{Bastille.jails_dir()}/#{jail}/root#{path}"

    cond do
      opts[:content] != nil ->
        with :ok <- File.mkdir_p(Path.dirname(host_path)),
             :ok <- File.write(host_path, opts[:content]) do
          :ok
        end

      opts[:append] != nil ->
        append_line_if_absent(host_path, opts[:append])

      true ->
        {:error, {:setup_file_op_missing_action, path}}
    end
  end

  defp run_setup_op(_jail, other), do: {:error, {:unknown_setup_op, other}}

  defp append_line_if_absent(host_path, line) do
    current =
      case File.read(host_path) do
        {:ok, c} -> c
        _ -> ""
      end

    already_present =
      current
      |> String.split("\n")
      |> Enum.any?(&(&1 == line))

    if already_present do
      :ok
    else
      new_contents =
        cond do
          current == "" -> line <> "\n"
          String.ends_with?(current, "\n") -> current <> line <> "\n"
          true -> current <> "\n" <> line <> "\n"
        end

      with :ok <- File.mkdir_p(Path.dirname(host_path)),
           :ok <- File.write(host_path, new_contents) do
        :ok
      end
    end
  end

  defp enable_service(jail, service) do
    case Bastille.cmd(jail, ["sysrc", "#{service}_enable=YES"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:jail_svc_enable_failed, jail, service, reason}}
    end
  end

  defp start_service_if_needed(jail, service) do
    case Bastille.cmd(jail, ["service", service, "status"]) do
      {:ok, _} ->
        {:ok, :jail_svc_already_running}

      {:error, _} ->
        case Bastille.cmd(jail, ["service", service, "start"]) do
          {:ok, _} -> {:ok, :jail_svc_started}
          {:error, reason} -> {:error, {:jail_svc_start_failed, jail, service, reason}}
        end
    end
  end

  defp stamp_jail_properties(%{dataset: nil}), do: :ok

  defp stamp_jail_properties(%{jail: jail_name, dataset: ds} = args) do
    # Dataset should already have pool prefix from plan
    pool_path = args[:pool_path] || ds

    if pool_path do
      pool_path |> Property.set("jail", to_string(jail_name))
      pool_path |> Property.set("managed", "true")
      args[:contains] |> maybe_set_property(pool_path, "contains")
    end

    :ok
  end
end
