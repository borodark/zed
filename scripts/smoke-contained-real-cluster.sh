#!/bin/sh
# scripts/smoke-contained-real-cluster.sh — clean + verify for Path C4
# (Zed.Examples.SmokeContainedRealCluster). Two jails, one hello_beam
# release each, cross-configured to peer with each other via PEER_NODE
# in the env file.

set -eu

POOL="mac_zroot"
JAILS="hello_beam_a hello_beam_b"
DATASETS="jails/hello_beam_a jails/hello_beam_b"
APP="hello_beam"

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

    # Env files include PEER_NODE
    for j in $JAILS; do
        env_file="/usr/local/bastille/jails/$j/root/var/db/zed/${APP}.env"
        if doas grep -q '^export PEER_NODE=' "${env_file}" 2>/dev/null; then
            log "  [OK] $j env file includes PEER_NODE"
        else
            log "  [FAIL] $j env file missing PEER_NODE"
            rc=1
        fi
    done

    # epmd reachable from host for both jails
    for ip in 10.17.89.93 10.17.89.94; do
        if nc -z -w 3 "$ip" 4369 2>/dev/null; then
            log "  [OK] epmd on $ip:4369 reachable"
        else
            log "  [FAIL] epmd on $ip:4369 not reachable"
            rc=1
        fi
    done

    # Both nodes registered with epmd inside their jails
    for j in $JAILS; do
        if jail_running "$j" && \
           doas bastille cmd "$j" sh -c "/opt/${APP}/current/erts-*/bin/epmd -names" 2>/dev/null | \
           grep -q "name ${APP} at port"; then
            log "  [OK] BEAM node ${APP} registered with epmd in $j"
        else
            log "  [FAIL] BEAM node ${APP} not registered in $j"
            rc=1
        fi
    done

    # Cluster proof: from a host BEAM connected to node A, Node.list should include node B.
    # Requires SMOKE_COOKIE to be set in the environment invoking this verify script.
    if [ -n "${SMOKE_COOKIE:-}" ]; then
        peers=$(cd ~/zed && env SMOKE_COOKIE="${SMOKE_COOKIE}" \
            iex --name verify@127.0.0.1 --cookie "${SMOKE_COOKIE}" -S mix -e '
              target = :"hello_beam@10.17.89.93"
              case :net_adm.ping(target) do
                :pong ->
                  peers = :rpc.call(target, Node, :list, [])
                  IO.puts(inspect(peers))
                other ->
                  IO.puts("ping_failed: " <> inspect(other))
              end
              System.halt()
            ' 2>&1 | tail -1)

        if echo "$peers" | grep -q "hello_beam@10.17.89.94"; then
            log "  [OK] node A sees node B in Node.list (${peers})"
        else
            log "  [FAIL] node A does not see B (${peers})"
            rc=1
        fi
    else
        log "  [SKIP] SMOKE_COOKIE not set — cluster proof requires it"
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
