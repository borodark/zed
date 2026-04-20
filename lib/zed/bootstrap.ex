defmodule Zed.Bootstrap do
  @moduledoc """
  Install-time orchestration of zed's own secrets.

  Creates two ZFS datasets under an arbitrary parent:

    <base>/zed              # carries com.zed:* metadata (fingerprints, paths)
    <base>/zed/secrets      # encrypted, holds the actual secret files

  The encrypted dataset is created with `keyformat=passphrase`,
  `keylocation=file://<tmp>` (so the passphrase can be piped from the
  caller without a TTY), and `canmount=noauto`. After creation the
  keylocation is rewritten to `prompt` so that future boot-time unlock
  is interactive.

  The `--base` parameter (not `--pool`) exists so that tests can run
  under a delegated subtree (`jeff/zed-test/bootstrap-test-<uuid>`)
  without needing pool-root access. Production callers pass the pool
  name; the same code path serves both.

  Idempotency: slots already stamped (fingerprint present in ZFS
  properties) are left untouched. Re-running `init/2` on an already
  bootstrapped base is a no-op.

  See `specs/iteration-plan.md` for slot catalog, rotation semantics,
  and planned Layer D modes.
  """

  alias Zed.Secrets.{Catalog, Generate, Store}
  alias Zed.ZFS
  alias Zed.ZFS.{Dataset, Property}

  @default_mountpoint "/var/db/zed/secrets"
  @default_encryption "aes-256-gcm"

  @doc """
  Initialize a zed deployment under `base`.

  Options (required):
    - `:passphrase` — dataset encryption passphrase (binary)

  Options (optional):
    - `:mountpoint` — where `<base>/zed/secrets` mounts. Default
      `"/var/db/zed/secrets"`. Tests should use a temp path.
    - `:admin_passwd` — plaintext admin password; if omitted, a
      random passphrase is generated and included in the banner.

  Returns `{:ok, %{generated: [...], paths: %{...}, banner: [...]}}`
  on success, `{:error, reason}` on failure.
  """
  def init(base, opts) when is_binary(base) and is_list(opts) do
    passphrase = Keyword.fetch!(opts, :passphrase)
    mountpoint = Keyword.get(opts, :mountpoint, @default_mountpoint)
    admin_passwd_plaintext = Keyword.get(opts, :admin_passwd)

    with :ok <- ensure_zed_dataset(base),
         :ok <- ensure_secrets_dataset(base, passphrase, mountpoint),
         :ok <- mount_secrets(base),
         {:ok, generated} <- generate_missing_slots(base, mountpoint, admin_passwd_plaintext),
         {:ok, snap} <- maybe_snapshot(base, generated) do
      {:ok,
       %{
         base: base,
         generated: generated,
         paths: path_map(mountpoint),
         banner: banner_from_generated(generated),
         snapshot: snap
       }}
    end
  end

  # Snapshot only when something was actually generated. The idempotent
  # no-op case has no new state to record, and taking a second snapshot
  # in the same second collides with the first on timestamp resolution.
  defp maybe_snapshot(base, generated) do
    if Enum.any?(generated, &(!&1[:skipped])) do
      snapshot(base)
    else
      {:ok, nil}
    end
  end

  @doc """
  List slots with fingerprint, age, and file-present check.

  Returns a list of `%{slot:, algo:, fingerprint:, created_at:,
  rotation_count:, file_present:}` maps, one per slot in the catalog.
  Slots not yet generated have `fingerprint: nil`.
  """
  def status(base) when is_binary(base) do
    props = Property.get_all("#{base}/zed")

    Enum.map(Catalog.slots(), fn slot ->
      path = Map.get(props, "secret.#{slot}.path")

      file_present =
        if path do
          fields = Catalog.fields(slot)

          cond do
            fields == [] -> false
            [:value] == fields -> File.regular?(path)
            true -> Enum.all?(fields, &field_file_present?(path, &1))
          end
        else
          false
        end

      %{
        slot: slot,
        algo: Catalog.algo(slot),
        fingerprint: Map.get(props, "secret.#{slot}.fingerprint"),
        created_at: Map.get(props, "secret.#{slot}.created_at"),
        rotation_count: Map.get(props, "secret.#{slot}.rotation_count"),
        consumers: Map.get(props, "secret.#{slot}.consumers"),
        file_present: file_present,
        path: path
      }
    end)
  end

  @doc """
  Recompute fingerprints, detect drift.

  Returns a list of `%{slot:, status:, ...}` maps. Status values:
    - `:ok`           — fingerprint matches file
    - `:unset`        — slot never generated
    - `:file_missing` — property stamped but file absent
    - `:drift`        — file exists but fingerprint does not match
  """
  def verify(base) when is_binary(base) do
    props = Property.get_all("#{base}/zed")

    Enum.map(Catalog.slots(), fn slot ->
      verify_slot(slot, props)
    end)
  end

  @doc """
  Export the public half of a keypair slot.

  Returns `{:ok, pub_bytes}` for keypair slots (e.g.
  `:ssh_host_ed25519`), `{:error, :no_pubkey}` for single-value slots.
  """
  def export_pubkey(base, slot) when is_binary(base) and is_atom(slot) do
    fields = Catalog.fields(slot)

    cond do
      fields == [] ->
        {:error, :unknown_slot}

      :pub not in fields ->
        {:error, :no_pubkey}

      true ->
        props = Property.get_all("#{base}/zed")

        case Map.get(props, "secret.#{slot}.path") do
          nil -> {:error, :slot_not_generated}
          path -> Store.read_value(path <> ".pub")
        end
    end
  end

  # ----------------------------------------------------------------------
  # Dataset setup
  # ----------------------------------------------------------------------

  defp ensure_zed_dataset(base) do
    ds = "#{base}/zed"

    if Dataset.exists?(ds) do
      :ok
    else
      case Dataset.create(ds, %{canmount: "off"}) do
        {:ok, _} -> :ok
        {:error, reason, code} -> {:error, {:zed_dataset_create_failed, reason, code}}
      end
    end
  end

  defp ensure_secrets_dataset(base, passphrase, mountpoint) do
    ds = "#{base}/zed/secrets"

    if Dataset.exists?(ds) do
      :ok
    else
      create_encrypted(ds, passphrase, mountpoint)
    end
  end

  # zfs create -o encryption=aes-256-gcm -o keyformat=passphrase
  #            -o keylocation=file://<tmp> -o mountpoint=... -o canmount=noauto <ds>
  # The keylocation=file:// avoids TTY. After create, rewrite to prompt
  # so future unlocks are interactive.
  defp create_encrypted(dataset, passphrase, mountpoint) do
    tmp = Path.join(System.tmp_dir!(), "zed-bootstrap-key-#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(tmp, passphrase)
      File.chmod!(tmp, 0o400)

      args = [
        "create",
        "-o",
        "encryption=#{@default_encryption}",
        "-o",
        "keyformat=passphrase",
        "-o",
        "keylocation=file://#{tmp}",
        "-o",
        "mountpoint=#{mountpoint}",
        "-o",
        "canmount=noauto",
        dataset
      ]

      case ZFS.cmd(args) do
        {:ok, _} ->
          # Rewrite keylocation to prompt for future operator-facing unlocks.
          _ = ZFS.cmd(["set", "keylocation=prompt", dataset])
          :ok

        {:error, out, code} ->
          {:error, {:zfs_create_failed, out, code}}
      end
    after
      File.rm(tmp)
    end
  end

  defp mount_secrets(base) do
    ds = "#{base}/zed/secrets"

    case ZFS.cmd(["mount", ds]) do
      {:ok, _} ->
        :ok

      {:error, out, _code} ->
        if String.contains?(out, "already mounted"), do: :ok, else: {:error, {:mount_failed, out}}
    end
  end

  # ----------------------------------------------------------------------
  # Slot generation
  # ----------------------------------------------------------------------

  defp generate_missing_slots(base, mountpoint, admin_passwd_plaintext) do
    props = Property.get_all("#{base}/zed")

    results =
      Enum.reduce(Catalog.slots(), [], fn slot, acc ->
        fp_key = "secret.#{slot}.fingerprint"

        if Map.has_key?(props, fp_key) do
          [%{slot: slot, skipped: true} | acc]
        else
          case generate_and_store(slot, mountpoint, base, admin_passwd_plaintext) do
            {:ok, result} -> [result | acc]
            {:error, reason} -> throw({:generate_failed, slot, reason})
          end
        end
      end)
      |> Enum.reverse()

    {:ok, results}
  catch
    {:generate_failed, slot, reason} -> {:error, {:generate_failed, slot, reason}}
  end

  defp generate_and_store(slot, mountpoint, base, admin_passwd_plaintext) do
    algo = Catalog.algo(slot)

    gen_opts =
      if slot == :admin_passwd and admin_passwd_plaintext do
        [plaintext: admin_passwd_plaintext]
      else
        []
      end

    with {:ok, material} <- Generate.by_algo(algo, gen_opts) do
      path = slot_path(mountpoint, slot)
      {fingerprint, banner} = store_material(slot, material, path)
      stamp_slot(base, slot, path, algo, fingerprint)

      {:ok,
       %{
         slot: slot,
         algo: algo,
         fingerprint: fingerprint,
         path: path,
         banner: banner,
         skipped: false
       }}
    end
  end

  # Per-slot storage: returns {fingerprint_string, banner_entry}.
  # The fingerprint is the final value stamped into the ZFS property —
  # verify/1 recomputes the same function on re-read. For most slots
  # this is raw-bytes sha256 (Store.fingerprint), but tls_selfsigned
  # uses the DER-decoded cert so the hash matches what a TLS client
  # derives on handshake.
  defp store_material(:beam_cookie, bytes, path) when is_binary(bytes) do
    Store.write_value(path, bytes)
    {Store.fingerprint(bytes), {:beam_cookie, :value_stored_quietly}}
  end

  defp store_material(:admin_passwd, %{plaintext: pw, hash: hash}, path) do
    Store.write_value(path, hash)
    {Store.fingerprint(hash), {:admin_passwd, :plaintext_once, pw}}
  end

  defp store_material(:ssh_host_ed25519, %{priv: priv, pub: pub}, path) do
    Store.write_value(path, priv)
    Store.write_value(path <> ".pub", pub, 0o444)
    {Store.fingerprint(priv),
     {:ssh_host_ed25519, :pubkey_b64, Base.encode64(pub, padding: false)}}
  end

  defp store_material(:tls_selfsigned, %{cert: cert_pem, key: key_pem}, path) do
    Store.write_value(path <> ".cert", cert_pem, 0o444)
    Store.write_value(path <> ".key", key_pem, 0o400)
    fp = cert_der_fingerprint(cert_pem)
    {fp, {:tls_selfsigned, :cert_fingerprint, fp}}
  end

  @doc """
  sha256 of the DER-encoded certificate inside a PEM binary.

  Matches the fingerprint a TLS client sees on the handshake leaf
  certificate. Used by A2b to pin the cert in the QR pairing payload.
  Returns `"sha256:<lowercase hex>"` or `"unknown"` if the PEM is
  malformed.
  """
  def cert_der_fingerprint(cert_pem) when is_binary(cert_pem) do
    cert_pem
    |> :public_key.pem_decode()
    |> Enum.find_value(fn
      {:Certificate, der, _} -> der
      _ -> nil
    end)
    |> case do
      nil ->
        "unknown"

      der ->
        "sha256:" <> (:crypto.hash(:sha256, der) |> Base.encode16(case: :lower))
    end
  end

  defp stamp_slot(base, slot, path, algo, fingerprint) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    consumers = Catalog.consumers(slot) |> Enum.map(&Atom.to_string/1) |> Enum.join(",")

    Property.set_many("#{base}/zed", %{
      "secret.#{slot}.fingerprint" => fingerprint,
      "secret.#{slot}.path" => path,
      "secret.#{slot}.algo" => Atom.to_string(algo),
      "secret.#{slot}.created_at" => now,
      "secret.#{slot}.rotation_count" => "0",
      "secret.#{slot}.consumers" => consumers
    })
  end

  # ----------------------------------------------------------------------
  # Verify
  # ----------------------------------------------------------------------

  defp verify_slot(slot, props) do
    stored_fp = Map.get(props, "secret.#{slot}.fingerprint")
    stored_path = Map.get(props, "secret.#{slot}.path")

    cond do
      is_nil(stored_fp) or is_nil(stored_path) ->
        %{slot: slot, status: :unset}

      true ->
        {read_path, hash_fn} = verify_target(slot, stored_path)

        cond do
          not File.regular?(read_path) ->
            %{slot: slot, status: :file_missing, expected: stored_fp, path: read_path}

          true ->
            case File.read(read_path) do
              {:ok, bytes} ->
                actual = hash_fn.(bytes)

                if actual == stored_fp do
                  %{slot: slot, status: :ok, fingerprint: actual}
                else
                  %{slot: slot, status: :drift, expected: stored_fp, actual: actual}
                end

              {:error, reason} ->
                %{slot: slot, status: :read_error, reason: reason}
            end
        end
    end
  end

  # Per-slot verify dispatch: which file to read, and how to hash it.
  # The default (single-value and keypair priv-at-base-path) is read
  # from the base path and hash raw bytes via Store.fingerprint. TLS
  # keeps the cert at <path>.cert and the fingerprint is over the DER.
  defp verify_target(:tls_selfsigned, base_path) do
    {base_path <> ".cert", &cert_der_fingerprint/1}
  end

  defp verify_target(_slot, base_path) do
    {base_path, &Store.fingerprint/1}
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  defp slot_path(mountpoint, slot), do: Path.join(mountpoint, Atom.to_string(slot))

  defp path_map(mountpoint) do
    Map.new(Catalog.slots(), fn slot -> {slot, slot_path(mountpoint, slot)} end)
  end

  defp field_file_present?(path, :priv), do: File.regular?(path)
  defp field_file_present?(path, :pub), do: File.regular?(path <> ".pub")
  defp field_file_present?(path, :cert), do: File.regular?(path <> ".cert")
  defp field_file_present?(path, :key), do: File.regular?(path <> ".key")
  defp field_file_present?(path, :value), do: File.regular?(path)
  defp field_file_present?(_, _), do: false

  defp snapshot(base) do
    ts = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    snap = "#{base}/zed@bootstrap-#{ts}"

    case ZFS.cmd(["snapshot", "-r", snap]) do
      {:ok, _} -> {:ok, snap}
      {:error, out, code} -> {:error, {:snapshot_failed, out, code}}
    end
  end

  defp banner_from_generated(generated) do
    generated
    |> Enum.reject(& &1[:skipped])
    |> Enum.map(& &1.banner)
    |> Enum.reject(fn
      {:beam_cookie, :value_stored_quietly} -> true
      _ -> false
    end)
  end
end
