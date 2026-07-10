#!/bin/sh
# scripts/smoke-zedweb.sh — clean + verify for Path C7
# (Zed.Examples.SmokeZedweb). One jail running Zed's own zedweb
# release; cookie + ZED_SECRET_KEY_BASE resolved from encrypted ZFS.
#
# Prereqs:
#   1. scripts/bootstrap-secrets.sh run once (adds zed_web_secret_key_base
#      + demo_cluster_cookie slots to mac_zroot/zed)
#   2. scripts/build-zedweb-release.sh — builds the tarball

set -eu

POOL="mac_zroot"
JAIL="smoke_zedweb"
IP="10.17.89.30"
PORT="4040"
DATASET="jails/smoke_zedweb"
APP="zedweb"
SECRETS_DATASET="${POOL}/zed"

log() { printf '=== %s ===\n' "$*"; }

clean() {
    log "clean: destroying jail + dataset (idempotent)"
    log "priming doas (enter password if prompted)"
    doas true

    if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "$JAIL"; then
        log "  destroying jail $JAIL"
        yes | doas bastille destroy -a -f "$JAIL" || true
    else
        log "  jail $JAIL not present"
    fi

    full="$POOL/$DATASET"
    if doas zfs list -H "$full" >/dev/null 2>&1; then
        log "  destroying dataset $full"
        doas zfs destroy -r "$full" || true
    else
        log "  dataset $full not present"
    fi

    env_host_path="/usr/local/bastille/jails/${JAIL}/root/var/db/zed/zedweb.env"
    if doas test -f "$env_host_path"; then
        log "  removing stale env file $env_host_path"
        doas rm -f "$env_host_path" || true
    fi
}

jail_running() { doas jls -j "$1" -q jid >/dev/null 2>&1; }

verify() {
    log "verify: asserting expected converged state"
    log "priming doas (enter password if prompted)"
    doas true

    rc=0

    # Catalog slots reachable via ZFS properties
    cookie_path=$(doas zfs get -H -o value com.zed:secret.demo_cluster_cookie.path "${SECRETS_DATASET}" 2>/dev/null || echo "-")
    skb_path=$(doas zfs get -H -o value com.zed:secret.zed_web_secret_key_base.path "${SECRETS_DATASET}" 2>/dev/null || echo "-")

    if [ "$cookie_path" != "-" ] && [ -n "$cookie_path" ]; then
        log "  [OK] com.zed:secret.demo_cluster_cookie.path stamped ($cookie_path)"
    else
        log "  [FAIL] demo_cluster_cookie slot not present (re-run bootstrap-secrets.sh)"
        rc=1
    fi

    if [ "$skb_path" != "-" ] && [ -n "$skb_path" ]; then
        log "  [OK] com.zed:secret.zed_web_secret_key_base.path stamped ($skb_path)"
    else
        log "  [FAIL] zed_web_secret_key_base slot not present (re-run bootstrap-secrets.sh after C7 pull)"
        rc=1
    fi

    # Jail up
    if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "$JAIL"; then
        log "  [OK] jail $JAIL exists"
    else
        log "  [FAIL] jail $JAIL missing"
        rc=1
    fi

    if jail_running "$JAIL"; then
        log "  [OK] jail $JAIL is running"
    else
        log "  [FAIL] jail $JAIL is NOT running"
        rc=1
    fi

    # Env file exists inside jail rootfs, contains both cookie AND secret_key_base
    env_host_path="/usr/local/bastille/jails/${JAIL}/root/var/db/zed/zedweb.env"

    env_cookie=$(doas awk -F'"' '/^export RELEASE_COOKIE=/ {print $2}' "$env_host_path" 2>/dev/null || echo "")
    env_skb=$(doas awk -F'"' '/^export ZED_SECRET_KEY_BASE=/ {print $2}' "$env_host_path" 2>/dev/null || echo "")
    env_serve=$(doas awk -F'"' '/^export ZED_SERVE=/ {print $2}' "$env_host_path" 2>/dev/null || echo "")

    disk_cookie=$(doas cat "$cookie_path" 2>/dev/null | tr -d '\n' || echo "")
    disk_skb=$(doas cat "$skb_path" 2>/dev/null | tr -d '\n' || echo "")

    if [ -n "$env_cookie" ] && [ "$env_cookie" = "$disk_cookie" ]; then
        log "  [OK] env RELEASE_COOKIE matches on-disk secret"
    else
        log "  [FAIL] env RELEASE_COOKIE does NOT match on-disk secret (env='${env_cookie}' disk='${disk_cookie}')"
        rc=1
    fi

    if [ -n "$env_skb" ] && [ "$env_skb" = "$disk_skb" ]; then
        log "  [OK] env ZED_SECRET_KEY_BASE matches on-disk secret"
    else
        log "  [FAIL] env ZED_SECRET_KEY_BASE does NOT match on-disk secret"
        rc=1
    fi

    if [ "$env_serve" = "1" ]; then
        log "  [OK] env ZED_SERVE=1 (endpoint supervised)"
    else
        log "  [FAIL] env ZED_SERVE='${env_serve}' — endpoint won't start"
        rc=1
    fi

    # BEAM up + role
    if jail_running "$JAIL"; then
        role=$(doas bastille cmd "$JAIL" sh -c "/opt/${APP}/current/bin/${APP} rpc 'IO.puts(inspect(Zed.Role.current()))'" 2>/dev/null | tail -1 | tr -d ' ')
        if [ "$role" = ":web" ]; then
            log "  [OK] Zed.Role.current() = :web inside jail"
        else
            log "  [FAIL] Zed.Role.current() = '${role}' (expected ':web')"
            rc=1
        fi
    fi

    # HTTP endpoint
    if curl -sf -m 5 "http://${IP}:${PORT}/health" >/dev/null 2>&1; then
        log "  [OK] http://${IP}:${PORT}/health returns 2xx"
    else
        code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://${IP}:${PORT}/health" 2>/dev/null || echo "-")
        log "  [FAIL] http://${IP}:${PORT}/health status='${code}'"
        rc=1
    fi

    if curl -sfI -m 5 "http://${IP}:${PORT}/" >/dev/null 2>&1; then
        log "  [OK] http://${IP}:${PORT}/ returns 2xx (LiveView root)"
    else
        code=$(curl -sI -m 5 -o /dev/null -w '%{http_code}' "http://${IP}:${PORT}/" 2>/dev/null || echo "-")
        log "  [FAIL] http://${IP}:${PORT}/ status='${code}'"
        rc=1
    fi

    if [ $rc -eq 0 ]; then
        log "verify: PASS"
    else
        log "verify: FAIL"
    fi

    return $rc
}

case "${1:-verify}" in
    clean)  clean ;;
    verify) verify ;;
    *)      echo "usage: $0 {clean|verify}"; exit 1 ;;
esac
