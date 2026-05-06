#!/bin/sh
# Fix livebook jail: restore elixir/iex scripts + add wrappers to PATH
# Run as: doas sh scripts/fix-livebook-elixir.sh

set -eu

JAIL_ROOT="/usr/local/bastille/jails/livebook/root"
BUILD="/home/io/livebook/_build/prod/rel/livebook"

echo "==> Restoring original elixir/iex scripts from build"
cp "$BUILD/releases/0.19.7/elixir" "$JAIL_ROOT/srv/livebook/releases/0.19.7/elixir"
cp "$BUILD/releases/0.19.7/iex"    "$JAIL_ROOT/srv/livebook/releases/0.19.7/iex"

echo "==> Creating /usr/local/bin wrappers"
# Thin jails share /usr/local via nullfs — write to jail's own /root/bin instead
mkdir -p "$JAIL_ROOT/root/bin"

cat > "$JAIL_ROOT/root/bin/elixir" <<'EOF'
#!/bin/sh
export PATH="/usr/local/lib/erlang27/bin:$PATH"
export ERL_LIBS="/srv/livebook/lib"
exec /srv/livebook/releases/0.19.7/elixir "$@"
EOF
chmod +x "$JAIL_ROOT/root/bin/elixir"

cat > "$JAIL_ROOT/root/bin/iex" <<'EOF'
#!/bin/sh
export PATH="/usr/local/lib/erlang27/bin:$PATH"
export ERL_LIBS="/srv/livebook/lib"
exec /srv/livebook/releases/0.19.7/iex "$@"
EOF
chmod +x "$JAIL_ROOT/root/bin/iex"

echo "==> Updating env.sh to include /root/bin in PATH"
ENV_SH="$JAIL_ROOT/srv/livebook/releases/0.19.7/env.sh"
cat > "$ENV_SH" <<'EOF'
#!/bin/sh
export PATH="/root/bin:/usr/local/lib/erlang27/bin:$PATH"
COOKIE_FILE="/var/db/zed/secrets/demo_cluster_cookie"
if [ -r "$COOKIE_FILE" ]; then
    RELEASE_COOKIE="$(cat "$COOKIE_FILE")"
    export RELEASE_COOKIE
    export LIVEBOOK_COOKIE="$RELEASE_COOKIE"
fi
export RELEASE_DISTRIBUTION=none
export LIVEBOOK_NODE="livebook@10.17.89.13"
export LIVEBOOK_IP="10.17.89.13"
export LIVEBOOK_PORT="8080"
export LIVEBOOK_TOKEN_ENABLED="false"
export RELEASE_MODE=interactive
cd $HOME
EOF

echo "==> Restarting livebook"
bastille cmd livebook sh -c 'pkill -9 beam.smp; pkill -9 epmd' 2>/dev/null || true
sleep 2
bastille cmd livebook /srv/livebook/bin/livebook daemon

echo "==> Done. Refresh browser."
