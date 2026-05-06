#!/bin/sh
# Restage zedweb release into jail and restart
# Run as: doas sh scripts/restage-zedweb.sh
set -eu

JAIL_ROOT="/usr/local/bastille/jails/zedweb/root"
SRC="/home/io/zed/_build/prod/rel/zedweb"

echo "==> Stopping zedweb"
bastille cmd zedweb sh -c 'pkill -9 beam.smp; pkill -9 epmd' 2>/dev/null || true
sleep 2

echo "==> Staging release"
cp -R "$SRC/"* "$JAIL_ROOT/srv/zedweb/"

echo "==> Writing env.sh"
ENV_DIR=$(find "$JAIL_ROOT/srv/zedweb/releases" -mindepth 1 -maxdepth 1 -type d | head -1)
cat > "$ENV_DIR/env.sh" <<'EOF'
#!/bin/sh
export PATH="/usr/local/lib/erlang27/bin:$PATH"
COOKIE_FILE="/var/db/zed/secrets/demo_cluster_cookie"
if [ -r "$COOKIE_FILE" ]; then
    RELEASE_COOKIE="$(cat "$COOKIE_FILE")"
    export RELEASE_COOKIE
fi
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="zedweb@10.17.89.10"
export ZED_SERVE=1
export ZED_WEB_BIND="10.17.89.10"
export ZED_WEB_PORT="4040"
export ZED_SECRET_KEY_BASE="$(cat /var/db/zed/secrets/beam_cookie)$(cat /var/db/zed/secrets/demo_cluster_cookie)"
export ZED_WEB_HOST="192.168.0.248"
EOF

echo "==> Starting zedweb"
bastille cmd zedweb /srv/zedweb/bin/zedweb daemon

echo "==> Connecting to exmc"
sleep 3
bastille cmd zedweb /srv/zedweb/bin/zedweb rpc 'Node.connect(:"exmc@10.17.89.14") |> IO.inspect(label: :exmc); IO.inspect(Node.list(), label: :peers)' 2>&1

echo "==> Done. Visit http://10.17.89.10:4040/cluster"
