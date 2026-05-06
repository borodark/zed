#!/bin/sh
# Restage exmc release into jail and restart with `start` (not daemon)
# Run as: doas sh scripts/restage-exmc.sh
set -eu

JAIL_ROOT="/usr/local/bastille/jails/exmc/root"
SRC="/home/io/exmc/_build/prod/rel/exmc"

echo "==> Stopping exmc"
bastille cmd exmc sh -c 'pkill -9 beam.smp; pkill -9 epmd' 2>/dev/null || true
sleep 2

echo "==> Staging release"
cp -R "$SRC/"* "$JAIL_ROOT/srv/exmc/"

echo "==> Writing env.sh"
ENV_DIR=$(find "$JAIL_ROOT/srv/exmc/releases" -mindepth 1 -maxdepth 1 -type d | head -1)
cat > "$ENV_DIR/env.sh" <<'EOF'
#!/bin/sh
export PATH="/usr/local/lib/erlang27/bin:$PATH"
COOKIE_FILE="/var/db/zed/secrets/demo_cluster_cookie"
if [ -r "$COOKIE_FILE" ]; then
    RELEASE_COOKIE="$(cat "$COOKIE_FILE")"
    export RELEASE_COOKIE
fi
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="exmc@10.17.89.14"
export ALPACA_API_KEY_ID="${ALPACA_API_KEY_ID:-demo}"
export ALPACA_SECRET_KEY="${ALPACA_SECRET_KEY:-demo}"
EOF

echo "==> Starting exmc (foreground mode for Livebook attach)"
bastille cmd exmc sh -c 'PATH=/usr/local/lib/erlang27/bin:$PATH /srv/exmc/bin/exmc start &'
sleep 3

echo "==> Verifying"
bastille cmd exmc sh -c 'pgrep beam.smp && echo RUNNING || echo NOT RUNNING'
echo "==> Done. Attach Livebook to exmc@10.17.89.14"
