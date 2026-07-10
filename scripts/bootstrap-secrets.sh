#!/bin/sh
# scripts/bootstrap-secrets.sh — one-time (idempotent) setup for
# Path C6. Creates <pool>/zed + <pool>/zed/secrets (encrypted,
# passphrase-locked), generates every slot in Zed.Secrets.Catalog,
# and stamps per-slot ZFS user properties.
#
# Re-running is safe: Bootstrap.init checks for existing slot
# fingerprints and skips already-present slots. Snapshot is only
# taken when new material is generated.
#
# Env var required:
#   BOOTSTRAP_PASSPHRASE — passphrase for the aes-256-gcm encrypted
#                          <pool>/zed/secrets dataset.
#
# Env var optional:
#   ZED_POOL         — ZFS pool to install into. Default: mac_zroot.
#   ZED_MOUNTPOINT   — where the secrets dataset mounts. Default:
#                      /var/db/zed/secrets.

set -eu
: "${BOOTSTRAP_PASSPHRASE:?BOOTSTRAP_PASSPHRASE env var required}"

POOL="${ZED_POOL:-mac_zroot}"
MOUNTPOINT="${ZED_MOUNTPOINT:-/var/db/zed/secrets}"

cd "$(dirname "$0")/.."

echo "==> Bootstrap.init base=${POOL} mountpoint=${MOUNTPOINT}"
echo "    Passphrase from BOOTSTRAP_PASSPHRASE env (${#BOOTSTRAP_PASSPHRASE} chars)"

doas env \
    BOOTSTRAP_PASSPHRASE="${BOOTSTRAP_PASSPHRASE}" \
    ZED_POOL="${POOL}" \
    ZED_MOUNTPOINT="${MOUNTPOINT}" \
    mix run -e '
      base       = System.fetch_env!("ZED_POOL")
      passphrase = System.fetch_env!("BOOTSTRAP_PASSPHRASE")
      mountpoint = System.fetch_env!("ZED_MOUNTPOINT")

      case Zed.Bootstrap.init(base, passphrase: passphrase, mountpoint: mountpoint) do
        {:ok, result} ->
          {new, skipped} =
            Enum.split_with(result.generated, fn s -> not Map.get(s, :skipped, false) end)

          IO.puts("Generated (#{length(new)} new):")
          Enum.each(new, fn s -> IO.puts("  + #{s.slot}") end)

          IO.puts("Skipped (#{length(skipped)} already present):")
          Enum.each(skipped, fn s -> IO.puts("  = #{s.slot}") end)

          case result.snapshot do
            nil -> IO.puts("(no new snapshot taken — idempotent no-op)")
            snap -> IO.puts("Snapshot: #{inspect(snap)}")
          end

        {:error, reason} ->
          IO.puts(:stderr, "Bootstrap FAILED: #{inspect(reason)}")
          System.halt(1)
      end
    '

echo "==> Bootstrap complete."
