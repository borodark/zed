#!/bin/sh
# scripts/demo-converge.sh — orchestrate the off-docker-compose demo
# end-to-end on a single FreeBSD Mac Pro (mac-248 host).
#
# Splits the work cleanly:
#   - Zed converge writes ZFS state + cluster artifact + secrets metadata
#   - This script does bastille create/start, release staging, services
#
# Idempotent where possible. Re-running is safe: existing jails are
# noticed and skipped; existing release dirs are overwritten; the
# cluster artifact is rewritten every converge.
#
# Pre-conditions (validated in PHASE 0):
#   - Running as root (via doas)
#   - On FreeBSD 15.0
#   - Pool `zroot_mac` exists
#   - Bastille installed; 15.0-RELEASE bootstrapped
#   - bastille0 cloned interface up
#   - Five release dirs staged under ~io/zed/demo-releases/
#   - User `io` exists (release dirs are owned by io)
#
# Usage:
#   doas sh ~/zed/scripts/demo-converge.sh           # full run
#   doas sh ~/zed/scripts/demo-converge.sh --dry-run # plan only, no changes

set -eu

# ----------------------------------------------------------------------
# Configuration

POOL="${POOL:-zroot_mac}"
RELEASES_DIR="${RELEASES_DIR:-/home/io/zed/demo-releases}"
ZED_REPO="${ZED_REPO:-/home/io/zed}"
BASE_MOUNTPOINT="/var/db/zed"
BASTILLE_JAILS="/usr/local/bastille/jails"
RELEASE="15.0-RELEASE"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Five BEAM jails: <name> <ip> <release-name>
# release-name is the directory under RELEASES_DIR/ AND the binary
# name inside <release>/bin/<name>.
BEAM_JAILS="
zedweb    10.17.89.10  zedweb
craftplan 10.17.89.11  craftplan
plausible 10.17.89.12  plausible
livebook  10.17.89.13  livebook
exmc      10.17.89.14  exmc
"

# Two DB jails — bootstrapped by mac-248's existing scripts
DB_JAILS="
pg  10.17.89.20
ch  10.17.89.21
"

# ----------------------------------------------------------------------
# Pretty-printing

if [ -t 1 ]; then
    GREEN=$(tput setaf 2 2>/dev/null || printf '')
    RED=$(tput setaf 1 2>/dev/null || printf '')
    YELLOW=$(tput setaf 3 2>/dev/null || printf '')
    BOLD=$(tput bold 2>/dev/null || printf '')
    RESET=$(tput sgr0 2>/dev/null || printf '')
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

phase() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$RESET"; }
ok()    { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
bad()   { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }
note()  { printf '  · %s\n' "$1"; }

run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '  [dry] %s\n' "$*"
    else
        eval "$@"
    fi
}

# ----------------------------------------------------------------------
phase "PHASE 0: pre-flight"

[ "$(id -u)" = "0" ] || bad "must run as root (use doas)"
[ "$(uname -s)" = "FreeBSD" ] || bad "must run on FreeBSD; got $(uname -s)"

zpool list -H -o name "$POOL" >/dev/null 2>&1 \
    || bad "pool $POOL not found; check POOL env var"
ok "pool $POOL"

command -v bastille >/dev/null 2>&1 || bad "bastille not installed"
ok "bastille installed: $(pkg info -E bastille 2>/dev/null | head -1)"

[ -d "/usr/local/bastille/releases/$RELEASE" ] \
    || bad "bastille release $RELEASE not bootstrapped — run: bastille bootstrap $RELEASE update"
ok "$RELEASE bootstrapped"

ifconfig bastille0 >/dev/null 2>&1 || bad "bastille0 missing — run scripts/host-bring-up.sh first"
ok "bastille0 interface up"

[ -d "$RELEASES_DIR" ] || bad "releases dir not found: $RELEASES_DIR"
for app in zedweb craftplan plausible livebook exmc; do
    [ -x "$RELEASES_DIR/$app/bin/$app" ] \
        || bad "missing release: $RELEASES_DIR/$app/bin/$app"
done
ok "all 5 release dirs present at $RELEASES_DIR"

# ----------------------------------------------------------------------
phase "PHASE 1: zed bootstrap (secrets + cluster cookie)"

ZED_BASE="$POOL"

# init is idempotent: existing datasets are kept, existing slots are
# skipped, only missing slots get generated. Always run it so new
# catalog entries (demo_cluster_cookie, pg_admin_passwd, etc.) get
# created even when the base dataset already exists.
if zfs list -H -o name "${ZED_BASE}/zed" >/dev/null 2>&1; then
    ok "${ZED_BASE}/zed already exists; will generate any missing slots"
    PASSPHRASE="${PASSPHRASE:-}"
    if [ -z "$PASSPHRASE" ]; then
        bad "PASSPHRASE env var required to unlock existing secrets dataset"
    fi
else
    note "generating bootstrap passphrase + secrets"
    PASSPHRASE=$(openssl rand -base64 32 | tr -d '\n')
    printf '  bootstrap passphrase (RECORD THIS — needed for future unlocks):\n'
    printf '  %s\n\n' "$PASSPHRASE"
fi

cd "$ZED_REPO"
run "PASSPHRASE='$PASSPHRASE' ELIXIR_ERL_OPTIONS='+fnu' mix run -e \"
    Zed.Bootstrap.init(
      \\\"$ZED_BASE\\\",
      passphrase: System.get_env(\\\"PASSPHRASE\\\"),
      mountpoint: \\\"$BASE_MOUNTPOINT/secrets\\\"
    ) |> IO.inspect()
\""
if [ "$DRY_RUN" = "0" ]; then
    ok "bootstrap complete"
else
    note "(dry) would run bootstrap init"
fi

if [ "$DRY_RUN" = "1" ]; then
    note "(dry) skipping demo_cluster_cookie file check"
elif [ -r "$BASE_MOUNTPOINT/secrets/demo_cluster_cookie" ]; then
    ok "demo_cluster_cookie present"
else
    bad "demo_cluster_cookie still missing after bootstrap — check catalog slots"
fi

# ----------------------------------------------------------------------
phase "PHASE 2: zed converge (datasets + cluster artifact)"

cd "$ZED_REPO"
run "ELIXIR_ERL_OPTIONS='+fnu' MIX_ENV=prod mix run -e 'Zed.Examples.DemoOffCompose.converge() |> IO.inspect(label: :converge)'"

if [ "$DRY_RUN" = "0" ]; then
    ok "converge complete"
    [ -r "$BASE_MOUNTPOINT/cluster/demo.config" ] \
        || bad "cluster artifact not written; check converge output"
    note "cluster artifact: $BASE_MOUNTPOINT/cluster/demo.config"
    cat "$BASE_MOUNTPOINT/cluster/demo.config" 2>/dev/null | sed 's/^/    /'
else
    note "(dry) would write $BASE_MOUNTPOINT/cluster/demo.config"
fi

# ----------------------------------------------------------------------
phase "PHASE 3: bastille jails (5 BEAM + 2 DB)"

create_jail_if_missing() {
    name="$1"
    ip="$2"
    if bastille list 2>/dev/null | awk '{print $2}' | grep -qx "$name"; then
        ok "jail $name already exists"
    else
        note "creating $name @ $ip"
        run "bastille create $name $RELEASE $ip"
        ok "created $name"
    fi
}

# DB jails first — apps depend on them
echo "$DB_JAILS" | while read name ip; do
    [ -z "$name" ] && continue
    create_jail_if_missing "$name" "$ip"
done

# BEAM jails
echo "$BEAM_JAILS" | while read name ip rel_name; do
    [ -z "$name" ] && continue
    create_jail_if_missing "$name" "$ip"
done

# ----------------------------------------------------------------------
phase "PHASE 3b: install Erlang runtime in BEAM jails"

echo "$BEAM_JAILS" | while read name ip rel_name; do
    [ -z "$name" ] && continue
    note "installing erlang-runtime27 in $name"
    run "bastille pkg $name install -y erlang-runtime27"
    ok "$name: erlang-runtime27"
done

# ----------------------------------------------------------------------
phase "PHASE 4: DB bootstrap scripts"

if [ -x "$ZED_REPO/scripts/demo-pg-bootstrap.sh" ]; then
    run "$ZED_REPO/scripts/demo-pg-bootstrap.sh"
    ok "pg bootstrap"
else
    warn "demo-pg-bootstrap.sh not executable; skipping"
fi

if [ -x "$ZED_REPO/scripts/demo-ch-bootstrap.sh" ]; then
    run "$ZED_REPO/scripts/demo-ch-bootstrap.sh"
    ok "ch bootstrap"
else
    warn "demo-ch-bootstrap.sh not executable; skipping"
fi

# ----------------------------------------------------------------------
phase "PHASE 5: nullfs mount — cluster artifact + cookie into each BEAM jail"

# Each BEAM jail gets <BASE_MOUNTPOINT> mounted ro at /var/db/zed
# so the app's runtime.exs can read /var/db/zed/cluster/demo.config
# and /var/db/zed/secrets/demo_cluster_cookie identically across jails.
mount_zed_into_jail() {
    name="$1"
    target="$BASTILLE_JAILS/$name/root/var/db/zed"
    secrets_target="$target/secrets"

    # Mount the base /var/db/zed (cluster artifact lives here)
    if [ ! -d "$target" ]; then
        run "mkdir -p $target"
    fi
    if mount -t nullfs | grep -q "on $target "; then
        ok "$name: /var/db/zed already mounted"
    else
        run "mount -t nullfs -o ro $BASE_MOUNTPOINT $target"
        ok "$name: nullfs ro mount of $BASE_MOUNTPOINT"
    fi

    # Mount secrets separately — it's a child ZFS dataset with its own
    # mountpoint, so nullfs of the parent doesn't include it.
    if [ ! -d "$secrets_target" ]; then
        run "mkdir -p $secrets_target"
    fi
    if mount -t nullfs | grep -q "on $secrets_target "; then
        ok "$name: /var/db/zed/secrets already mounted"
    else
        run "mount -t nullfs -o ro $BASE_MOUNTPOINT/secrets $secrets_target"
        ok "$name: nullfs ro mount of secrets"
    fi
}

echo "$BEAM_JAILS" | while read name ip rel_name; do
    [ -z "$name" ] && continue
    mount_zed_into_jail "$name"
done

# ----------------------------------------------------------------------
phase "PHASE 6: stage releases into BEAM jails"

# Stop any running BEAMs first — cp can't overwrite binaries in use
echo "$BEAM_JAILS" | while read name ip rel_name; do
    [ -z "$name" ] && continue
    if [ -x "$BASTILLE_JAILS/$name/root/srv/$rel_name/bin/$rel_name" ]; then
        note "stopping $name (if running)"
        run "bastille cmd $name /srv/$rel_name/bin/$rel_name stop 2>/dev/null || bastille cmd $name sh -c 'pkill -9 beam.smp 2>/dev/null; pkill -9 epmd 2>/dev/null; pkill -9 run_erl 2>/dev/null' 2>/dev/null || true"
        sleep 1
    fi
done

stage_release() {
    name="$1"
    rel_name="$2"
    src="$RELEASES_DIR/$rel_name"
    dst="$BASTILLE_JAILS/$name/root/srv/$rel_name"

    run "mkdir -p $dst"
    note "  $src/  →  $dst/"
    run "cp -R $src/* $dst/"
    ok "$name: release staged at /srv/$rel_name"
}

echo "$BEAM_JAILS" | while read name ip rel_name; do
    [ -z "$name" ] && continue
    stage_release "$name" "$rel_name"
done

# Write env.sh for every BEAM jail. Every app needs:
#   - RELEASE_DISTRIBUTION=name (longnames for IP-based node names)
#   - RELEASE_COOKIE from the secrets dataset
#   - RELEASE_NODE set to <app>@<jail-ip>
# Livebook additionally needs LIVEBOOK_* env vars and its own
# distribution management replaced (its upstream env.sh uses bash-isms
# that break under /bin/sh in the jail).
write_env_sh() {
    name="$1"
    ip="$2"
    rel_name="$3"
    env_dir=$(find "$BASTILLE_JAILS/$name/root/srv/$rel_name/releases" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ -z "$env_dir" ] && return

    if [ "$rel_name" = "livebook" ]; then
        note "writing env.sh for livebook (replaces upstream)"
        cat > "$env_dir/env.sh" <<ENVEOF
#!/bin/sh
# Demo cluster env for livebook — replaces upstream's bash-heavy env.sh
COOKIE_FILE="/var/db/zed/secrets/demo_cluster_cookie"
if [ -r "\$COOKIE_FILE" ]; then
    RELEASE_COOKIE="\$(cat "\$COOKIE_FILE")"
    export RELEASE_COOKIE
    export LIVEBOOK_COOKIE="\$RELEASE_COOKIE"
fi
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="livebook@${ip}"
export LIVEBOOK_NODE="livebook@${ip}"
export LIVEBOOK_IP="${ip}"
export LIVEBOOK_PORT="8080"
export LIVEBOOK_PASSWORD="\$(cat /var/db/zed/secrets/livebook_passwd 2>/dev/null || echo demo)"
export RELEASE_MODE=interactive
cd \$HOME
ENVEOF
        chmod +x "$env_dir/env.sh"
        ok "livebook: env.sh written"
    else
        note "writing env.sh for $rel_name (cookie + node + longnames)"
        cat > "$env_dir/env.sh" <<ENVEOF
#!/bin/sh
COOKIE_FILE="/var/db/zed/secrets/demo_cluster_cookie"
if [ -r "\$COOKIE_FILE" ]; then
    RELEASE_COOKIE="\$(cat "\$COOKIE_FILE")"
    export RELEASE_COOKIE
fi
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="${rel_name}@${ip}"
ENVEOF
        ok "$rel_name: env.sh written"
    fi
}

echo "$BEAM_JAILS" | while read name ip rel_name; do
    [ -z "$name" ] && continue
    write_env_sh "$name" "$ip" "$rel_name"
done

# ----------------------------------------------------------------------
phase "PHASE 7: start BEAMs"

start_beam() {
    name="$1"
    rel_name="$2"
    cmd="/srv/$rel_name/bin/$rel_name daemon"
    note "starting $name: $cmd"
    run "bastille cmd $name $cmd" || warn "$name start may have non-zero exit (daemon detach)"
    ok "$name started"
}

echo "$BEAM_JAILS" | while read name ip rel_name; do
    [ -z "$name" ] && continue
    start_beam "$name" "$rel_name"
done

note "waiting 10s for nodes to settle"
[ "$DRY_RUN" = "0" ] && sleep 10

# ----------------------------------------------------------------------
phase "PHASE 8: cluster verification"

if [ "$DRY_RUN" = "1" ]; then
    note "skipped under --dry-run"
else
    cookie=$(cat "$BASE_MOUNTPOINT/secrets/demo_cluster_cookie")
    note "querying zedweb@10.17.89.10 for Node.list()"

    bastille cmd zedweb /srv/zedweb/bin/zedweb rpc \
        "IO.inspect(Node.list(), label: :nodes)" 2>&1 \
        | sed 's/^/    /' \
        || warn "Node.list query failed — peer connection may need more time"
fi

# ----------------------------------------------------------------------
printf '\n%sdemo converge complete%s\n' "$BOLD" "$RESET"
printf '  zedweb dashboard:  http://10.17.89.10:4040/admin\n'
printf '  livebook:          http://10.17.89.13:8080/\n'
printf '  craftplan:         http://10.17.89.11:4000/\n'
printf '  plausible:         http://10.17.89.12:8000/\n'
printf '  exmc:              (BEAM-only, no http)\n'
printf '\n'
printf 'next: open browser to one of the URLs above, or attach a remsh:\n'
printf '  doas bastille console zedweb\n'
printf '  iex --remsh zedweb@10.17.89.10 --cookie "$(cat /var/db/zed/secrets/demo_cluster_cookie)"\n'
