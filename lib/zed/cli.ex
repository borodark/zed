defmodule Zed.CLI do
  @moduledoc """
  CLI entry point for the `zed` escript.
  """

  def main(args) do
    {opts, command, _} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          verbose: :boolean,
          target: :string,
          module: :string,
          base: :string,
          mountpoint: :string,
          slot: :string,
          admin_passwd: :string,
          port: :integer,
          bind: :string
        ],
        aliases: [n: :dry_run, v: :verbose, t: :target, m: :module, b: :base]
      )

    case command do
      ["converge"] -> cmd_converge(opts)
      ["diff"] -> cmd_diff(opts)
      ["rollback"] -> cmd_rollback(opts)
      ["status"] -> cmd_status(opts)
      ["version"] -> IO.puts("zed #{Zed.version()}")
      ["bootstrap", "init"] -> cmd_bootstrap_init(opts)
      ["bootstrap", "status"] -> cmd_bootstrap_status(opts)
      ["bootstrap", "verify"] -> cmd_bootstrap_verify(opts)
      ["bootstrap", "rotate"] -> cmd_bootstrap_rotate(opts)
      ["bootstrap", "export-pubkey"] -> cmd_bootstrap_export_pubkey(opts)
      ["serve"] -> cmd_serve(opts)
      _ -> print_usage()
    end
  end

  defp cmd_converge(opts) do
    ir = load_ir(opts)
    dry_run = Keyword.get(opts, :dry_run, false)

    result = Zed.Converge.run(ir, dry_run: dry_run)
    Zed.Output.print_result(result)
  end

  defp cmd_diff(opts) do
    ir = load_ir(opts)
    diff = Zed.Converge.Diff.compute(ir)
    Zed.Output.print_diff(diff)
  end

  defp cmd_rollback(opts) do
    ir = load_ir(opts)
    target = Keyword.get(opts, :target, "@latest")

    case Zed.Converge.rollback(ir, target) do
      :ok -> IO.puts("Rollback complete.")
      {:error, reason} -> IO.puts("Rollback failed: #{inspect(reason)}")
    end
  end

  defp cmd_status(opts) do
    ir = load_ir(opts)
    state = Zed.State.read(ir)
    Zed.Output.print_status(state)
  end

  # --- bootstrap commands ---

  defp cmd_bootstrap_init(opts) do
    base = require_base!(opts)
    passphrase = resolve_passphrase(opts)
    mountpoint = Keyword.get(opts, :mountpoint, "/var/db/zed/secrets")

    init_opts = [passphrase: passphrase, mountpoint: mountpoint]

    init_opts =
      case Keyword.get(opts, :admin_passwd) do
        nil -> init_opts
        pw -> Keyword.put(init_opts, :admin_passwd, pw)
      end

    case Zed.Bootstrap.init(base, init_opts) do
      {:ok, result} ->
        print_bootstrap_banner(result)
        :ok

      {:error, reason} ->
        IO.puts("bootstrap init failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp cmd_bootstrap_status(opts) do
    base = require_base!(opts)
    rows = Zed.Bootstrap.status(base)

    IO.puts(
      "\nSlot                  Algo              Fingerprint                                                      File  Age"
    )

    IO.puts(
      "---------------------  ----------------  ---------------------------------------------------------------  ----  -------------------------"
    )

    for row <- rows do
      IO.puts(
        "#{pad(row.slot, 21)}  #{pad(row.algo || "-", 16)}  #{pad(row.fingerprint || "-", 63)}  #{pad(row.file_present, 4)}  #{row.created_at || "-"}"
      )
    end

    :ok
  end

  defp cmd_bootstrap_verify(opts) do
    base = require_base!(opts)
    results = Zed.Bootstrap.verify(base)
    any_bad = Enum.any?(results, &(&1.status not in [:ok, :unset]))

    for r <- results do
      tag =
        case r.status do
          :ok -> "OK"
          :unset -> "UNSET"
          :file_missing -> "MISSING"
          :drift -> "DRIFT"
          _ -> "ERROR"
        end

      IO.puts("#{pad(tag, 8)} #{r.slot}  #{inspect(Map.drop(r, [:slot, :status]))}")
    end

    if any_bad, do: System.halt(2), else: :ok
  end

  defp cmd_bootstrap_rotate(_opts) do
    IO.puts("bootstrap rotate: not yet implemented (A1 ships init/status/verify/export-pubkey).")
    System.halt(2)
  end

  defp cmd_bootstrap_export_pubkey(opts) do
    base = require_base!(opts)

    slot =
      opts
      |> Keyword.fetch!(:slot)
      |> String.to_atom()

    case Zed.Bootstrap.export_pubkey(base, slot) do
      {:ok, bytes} ->
        IO.puts(Base.encode64(bytes, padding: false))

      {:error, reason} ->
        IO.puts("export-pubkey failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp require_base!(opts) do
    case Keyword.get(opts, :base) do
      nil ->
        IO.puts("Error: --base <dataset> is required (e.g. --base jeff for production, jeff/zed-test/x for tests).")
        System.halt(1)

      base ->
        base
    end
  end

  defp resolve_passphrase(opts) do
    case System.get_env("ZED_BOOTSTRAP_PASSPHRASE") do
      nil ->
        case Keyword.get(opts, :passphrase) do
          nil ->
            IO.puts("Error: set ZED_BOOTSTRAP_PASSPHRASE, or pass --passphrase.")
            System.halt(1)

          pw ->
            pw
        end

      pw ->
        pw
    end
  end

  defp print_bootstrap_banner(%{base: base, snapshot: snap, banner: banner, paths: paths}) do
    IO.puts("""

    zed bootstrap complete.
      base:      #{base}
      snapshot:  #{snap}
      secrets:   #{paths[:beam_cookie] |> Path.dirname()}
    """)

    plaintexts =
      Enum.flat_map(banner, fn
        {:admin_passwd, :plaintext_once, pw} -> [{"admin password", pw}]
        _ -> []
      end)

    if plaintexts != [] do
      IO.puts("GENERATED — save now, will not be shown again:")

      for {label, val} <- plaintexts do
        IO.puts("  #{label}: #{val}")
      end
    end

    pubs =
      Enum.flat_map(banner, fn
        {slot, :pubkey_b64, b64} -> [{"#{slot} pubkey", b64}]
        {slot, :cert_fingerprint, fp} -> [{"#{slot} cert fingerprint", fp}]
        _ -> []
      end)

    if pubs != [] do
      IO.puts("")
      IO.puts("PUBLIC MATERIAL (safe to share):")

      for {label, val} <- pubs do
        IO.puts("  #{label}: #{val}")
      end
    end
  end

  defp pad(val, width) do
    str = to_string(val)
    pad_len = max(width - String.length(str), 0)
    str <> String.duplicate(" ", pad_len)
  end

  # --- serve ---

  defp cmd_serve(opts) do
    base = require_base!(opts)
    Application.put_env(:zed, :base, base)

    port = Keyword.get(opts, :port, 4040)
    bind = Keyword.get(opts, :bind, "127.0.0.1")

    bind_ip =
      case bind |> String.split(".") |> Enum.map(&Integer.parse/1) do
        [{a, ""}, {b, ""}, {c, ""}, {d, ""}] -> {a, b, c, d}
        _ -> {127, 0, 0, 1}
      end

    secret_key_base =
      System.get_env("ZED_SECRET_KEY_BASE") ||
        (
          IO.puts(
            "warning: ZED_SECRET_KEY_BASE not set; generating an ephemeral one. Sessions won't survive restart."
          )

          :crypto.strong_rand_bytes(64) |> Base.encode64()
        )

    tls_cert = System.get_env("ZED_TLS_CERT")
    tls_key = System.get_env("ZED_TLS_KEY")

    endpoint_opts =
      [
        secret_key_base: secret_key_base,
        server: true,
        url: [host: System.get_env("ZED_WEB_HOST") || "localhost", port: port]
      ]

    endpoint_opts =
      if tls_cert && tls_key && File.exists?(tls_cert) && File.exists?(tls_key) do
        Keyword.put(endpoint_opts, :https,
          ip: bind_ip,
          port: port,
          certfile: tls_cert,
          keyfile: tls_key,
          otp_app: :zed
        )
      else
        IO.puts("note: running on plain HTTP (no ZED_TLS_CERT/ZED_TLS_KEY set)")
        Keyword.put(endpoint_opts, :http, ip: bind_ip, port: port)
      end

    merged =
      :zed
      |> Application.get_env(ZedWeb.Endpoint, [])
      |> Keyword.merge(endpoint_opts)

    Application.put_env(:zed, ZedWeb.Endpoint, merged)

    children = [ZedWeb.Endpoint]

    {:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one, name: Zed.WebSupervisor)

    IO.puts("zed-web serving on #{bind}:#{port} (base=#{base})")
    IO.puts("  admin login: #{scheme(tls_cert, tls_key)}://#{bind}:#{port}/admin/login")

    print_pairing_qr(base, bind_ip, port, tls_cert, tls_key)

    Process.sleep(:infinity)
  end

  defp scheme(cert, key) when is_binary(cert) and is_binary(key), do: "https"
  defp scheme(_, _), do: "http"

  # Issue a short-lived OTT and render a :zed_admin QR on the serve-start
  # console. Companion app scans → logs in without typing a password.
  # Silently skipped if cert fingerprint or OTT issuance fail — fallback
  # is password login via the printed URL above.
  defp print_pairing_qr(base, bind_ip, port, tls_cert, _tls_key) do
    with {:ok, cert_fp} <- read_cert_fingerprint(base, tls_cert),
         {:ok, %{ott: ott, expires_at: exp}} <-
           Zed.Admin.OTT.issue(ttl_seconds: 300, issued_by: :serve_startup) do
      payload = Zed.QR.admin_payload(bind_ip, port, cert_fp, ott, exp)

      IO.puts("")
      IO.puts("Scan to log in (valid 5 min):")

      case Zed.QR.render(payload) do
        {:ok, ansi} ->
          IO.write(ansi)
          IO.puts("  node:        #{inspect(Node.self())}")
          IO.puts("  host:port:   #{format_ip(bind_ip)}:#{port}")
          IO.puts("  cert fp:     #{cert_fp}")
          IO.puts("  ott expires: #{format_unix(exp)} (#{exp})")

        {:error, reason} ->
          IO.puts("  (QR render failed: #{inspect(reason)}; use password login)")
      end
    else
      _ -> :ok
    end
  end

  defp read_cert_fingerprint(base, tls_cert) when is_binary(tls_cert) do
    case File.read(tls_cert) do
      {:ok, pem} -> {:ok, Zed.Bootstrap.cert_der_fingerprint(pem)}
      _ -> fallback_fingerprint(base)
    end
  end

  defp read_cert_fingerprint(base, _), do: fallback_fingerprint(base)

  defp fallback_fingerprint(base) do
    # Pull from the stamped tls_selfsigned slot if available
    props = Zed.ZFS.Property.get_all("#{base}/zed")

    with path when is_binary(path) <- Map.get(props, "secret.tls_selfsigned.path"),
         {:ok, pem} <- File.read(path <> ".cert") do
      {:ok, Zed.Bootstrap.cert_der_fingerprint(pem)}
    else
      _ -> {:error, :no_cert}
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_unix(unix) do
    DateTime.from_unix!(unix) |> DateTime.to_string()
  end

  # --- existing ---

  defp load_ir(opts) do
    case Keyword.get(opts, :module) do
      nil ->
        IO.puts("Error: --module (-m) is required.")
        System.halt(1)

      mod_string ->
        module = Module.concat([mod_string])

        if Code.ensure_loaded?(module) && function_exported?(module, :__zed_ir__, 0) do
          module.__zed_ir__()
        else
          IO.puts("Error: #{mod_string} is not a Zed deployment module.")
          IO.puts("Make sure it uses `use Zed.DSL` and defines a `deploy` block.")
          System.halt(1)
        end
    end
  end

  defp print_usage do
    IO.puts("""
    zed — ZFS + Elixir Deploy

    Usage: zed <command> [options]

    Commands:
      converge                   Make reality match the declared state
      diff                       Show what would change
      rollback                   Roll back to a previous version or snapshot
      status                     Show current deployment state
      version                    Show zed version

      bootstrap init             Create <base>/zed, generate missing slots
      bootstrap status           Show per-slot fingerprint, age, file-presence
      bootstrap verify           Recompute fingerprints, report drift
      bootstrap rotate           (not yet implemented in A1)
      bootstrap export-pubkey    Print base64 pubkey for a keypair slot

      serve                      Start zed-web admin UI (LiveView on a port)

    Options:
      -m, --module MODULE        Deployment module (e.g., MyInfra.Trading)
      -n, --dry-run              Show what would happen without applying
      -t, --target TARGET        Rollback target (version string or @latest)
      -v, --verbose              Verbose output
      -b, --base DATASET         Parent dataset for bootstrap (e.g. jeff)
      --mountpoint PATH          Override <base>/zed/secrets mountpoint
      --slot NAME                Slot name for bootstrap export-pubkey
      --admin-passwd STRING      Supply admin password (or auto-generate)
      --port N                   Port for zed serve (default 4040)
      --bind ADDR                Bind address for zed serve (default 127.0.0.1)

    Environment:
      ZED_BOOTSTRAP_PASSPHRASE   Passphrase for encrypted secrets dataset
      ZED_SECRET_KEY_BASE        Phoenix session signing key (serve)
      ZED_TLS_CERT, ZED_TLS_KEY  PEM paths for HTTPS (serve); HTTP if unset
    """)
  end
end
