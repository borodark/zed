#!/bin/sh
# demo-serve.sh — start zed-web against the bootstrapped demo base.
#
# Reads the cert/key file paths from the stamped tls_selfsigned slot
# on <ZED_DEMO_BASE>/zed. Generates an ephemeral ZED_SECRET_KEY_BASE
# per run (sessions will not survive restart — fine for demo use).
#
# Override via env:
#   ZED_DEMO_BASE   parent dataset    (default jeff/zed-test/manual)
#   ZED_DEMO_BIND   bind address      (default 0.0.0.0)
#   ZED_DEMO_PORT   listen port       (default 4040)

set -eu

BASE=${ZED_DEMO_BASE:-jeff/zed-test/manual}
BIND=${ZED_DEMO_BIND:-0.0.0.0}
PORT=${ZED_DEMO_PORT:-4040}

CERT_BASE=$(zfs get -H -o value "com.zed:secret.tls_selfsigned.path" "$BASE/zed")

if [ -z "$CERT_BASE" ] || [ "$CERT_BASE" = "-" ]; then
  echo "error: no tls_selfsigned.path stamped on $BASE/zed." >&2
  echo "run scripts/demo-bootstrap.sh first." >&2
  exit 1
fi

ZED_SECRET_KEY_BASE=$(elixir -e 'IO.puts(:crypto.strong_rand_bytes(64) |> Base.encode64())')
export ZED_SECRET_KEY_BASE
export ZED_TLS_CERT=${CERT_BASE}.cert
export ZED_TLS_KEY=${CERT_BASE}.key

echo "BASE=$BASE"
echo "BIND=$BIND PORT=$PORT"
echo "CERT=$ZED_TLS_CERT"
echo "KEY=$ZED_TLS_KEY"
echo

exec mix run --no-halt -e "Zed.CLI.main([
  \"serve\",
  \"--base\", \"$BASE\",
  \"--bind\", \"$BIND\",
  \"--port\", \"$PORT\"
])"
