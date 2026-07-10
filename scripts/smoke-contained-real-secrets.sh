#!/bin/sh
# scripts/smoke-contained-real-secrets.sh — clean + verify for
# Path C6 (Zed.Examples.SmokeContainedRealSecrets). Two jails, both
# with cookie {:secret, :beam_cookie} resolved from encrypted ZFS.
#
# Prereq: run scripts/bootstrap-secrets.sh once to generate
# mac_zroot/zed + mac_zroot/zed/secrets and stamp per-slot ZFS
# properties.

set -eu

POOL="mac_zroot"
JAILS="hello_beam_a95 hello_beam_a96"
IPS="10.17.89.95 10.17.89.96"
DATASETS="jails/hello_beam_a95 jails/hello_beam_a96"
APP="hello_beam"
SECRETS_DATASET="${POOL}/zed"

log() { printf '=== %s ===\n' "$*"; }

clean() {
    log "clean: destroying jails + datasets (idempotent)"
    log "priming doas (enter password if prompted)"
    doas true

    for j in $JAILS; do
        if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "$j"; then
            log "  destroying jail $j"
            yes | doas bastille destroy -a -f "$j" || true
        else
            log "  jail $j not present"
        fi
    done

    for d in $DATASETS; do
        full="$POOL/$d"
        if doas zfs list -H "$full" >/dev/null 2>&1; then
            log "  destroying dataset $full"
            doas zfs destroy -r "$full" || true
        else
            log "  dataset $full not present"
        fi
    done
}

jail_running() { doas jls -j "$1" -q jid >/dev/null 2>&1; }

verify() {
    log "verify: asserting expected converged state"
    log "priming doas (enter password if prompted)"
    doas true

    rc=0

    # ZFS secrets dataset infrastructure — this is what Bootstrap sets up
    if doas zfs list -H "${SECRETS_DATASET}" >/dev/null 2>&1; then
        log "  [OK] Zed metadata dataset ${SECRETS_DATASET} exists"
    else
        log "  [FAIL] Zed metadata dataset ${SECRETS_DATASET} missing (run bootstrap-secrets.sh)"
        rc=1
    fi

    if doas zfs list -H "${SECRETS_DATASET}/secrets" >/dev/null 2>&1; then
        encryption=$(doas zfs get -H -o value encryption "${SECRETS_DATASET}/secrets")
        if [ "$encryption" != "off" ] && [ -n "$encryption" ]; then
            log "  [OK] secrets dataset encrypted ($encryption)"
        else
            log "  [FAIL] secrets dataset NOT encrypted (got: $encryption)"
            rc=1
        fi
    else
        log "  [FAIL] ${SECRETS_DATASET}/secrets missing"
        rc=1
    fi

    # ZFS property points at the cookie file
    cookie_path=$(doas zfs get -H -o value com.zed:secret.beam_cookie.path "${SECRETS_DATASET}" 2>/dev/null || echo "-")
    if [ "$cookie_path" != "-" ] && [ -n "$cookie_path" ]; then
        log "  [OK] com.zed:secret.beam_cookie.path stamped ($cookie_path)"
    else
        log "  [FAIL] com.zed:secret.beam_cookie.path not stamped"
        rc=1
    fi

    # Cookie file exists at that path with tight mode
    if doas test -f "$cookie_path"; then
        mode=$(doas stat -f '%Lp' "$cookie_path" 2>/dev/null || echo "")
        if [ "$mode" = "400" ]; then
            log "  [OK] cookie file $cookie_path exists, mode 0400"
        else
            log "  [FAIL] cookie file exists but mode is $mode, expected 400"
            rc=1
        fi
    else
        log "  [FAIL] cookie file at $cookie_path not readable/absent"
        rc=1
    fi

    # Both jails up + running
    for j in $JAILS; do
        if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "$j"; then
            log "  [OK] jail $j exists"
        else
            log "  [FAIL] jail $j missing"
            rc=1
        fi

        if jail_running "$j"; then
            log "  [OK] jail $j is running"
        else
            log "  [FAIL] jail $j is NOT running"
            rc=1
        fi
    done

    # Env files exist, mode 0400, contain the SAME cookie
    a95_env="/usr/local/bastille/jails/hello_beam_a95/root/var/db/zed/hello_beam.env"
    a96_env="/usr/local/bastille/jails/hello_beam_a96/root/var/db/zed/hello_beam.env"

    a95_cookie=$(doas awk -F'"' '/^export RELEASE_COOKIE=/ {print $2}' "$a95_env" 2>/dev/null || echo "")
    a96_cookie=$(doas awk -F'"' '/^export RELEASE_COOKIE=/ {print $2}' "$a96_env" 2>/dev/null || echo "")
    disk_cookie=$(doas cat "$cookie_path" 2>/dev/null | tr -d '\n' || echo "")

    if [ -n "$a95_cookie" ] && [ "$a95_cookie" = "$a96_cookie" ]; then
        log "  [OK] both env files contain the same RELEASE_COOKIE value"
    else
        log "  [FAIL] env file cookies differ or empty (a95='${a95_cookie}' a96='${a96_cookie}')"
        rc=1
    fi

    if [ -n "$a95_cookie" ] && [ "$a95_cookie" = "$disk_cookie" ]; then
        log "  [OK] env file cookie matches on-disk secret"
    else
        log "  [FAIL] env file cookie does NOT match on-disk secret"
        rc=1
    fi

    # epmd + node registration
    for ip in $IPS; do
        if nc -z -w 3 "$ip" 4369 2>/dev/null; then
            log "  [OK] epmd on $ip:4369 reachable"
        else
            log "  [FAIL] epmd on $ip:4369 not reachable"
            rc=1
        fi
    done

    for j in $JAILS; do
        if jail_running "$j" && \
           doas bastille cmd "$j" sh -c "/opt/${APP}/current/erts-*/bin/epmd -names" 2>/dev/null | \
           grep -q "name ${APP} at port"; then
            log "  [OK] BEAM node ${APP} registered in $j"
        else
            log "  [FAIL] BEAM node ${APP} not registered in $j"
            rc=1
        fi
    done

    # Cluster proof: control BEAM uses the disk cookie to connect
    if [ -n "$disk_cookie" ]; then
        peers=$(cd ~/zed && env DISK_COOKIE="${disk_cookie}" \
            elixir --erl "-name verify@127.0.0.1 -setcookie ${disk_cookie}" \
                   -S mix run -e '
                     target = :"hello_beam@10.17.89.95"
                     case :net_adm.ping(target) do
                       :pong ->
                         peers = :rpc.call(target, Node, :list, [])
                         IO.puts("__PEERS__" <> inspect(peers))
                       other ->
                         IO.puts("__PEERS__ping_failed:" <> inspect(other))
                     end
                   ' 2>&1 | grep "__PEERS__" | sed "s/__PEERS__//")

        if echo "$peers" | grep -q "hello_beam@10.17.89.96"; then
            log "  [OK] node .95 sees .96 in Node.list (${peers})"
        else
            log "  [FAIL] node .95 does not see .96 (${peers})"
            rc=1
        fi
    else
        log "  [SKIP] disk_cookie unset — cluster proof unavailable"
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
