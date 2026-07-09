#!/bin/sh
# scripts/smoke-contained-real5.sh — clean + verify for Path C5
# (Zed.Examples.SmokeContainedReal5). Five jails, five hello_beam
# nodes discovering each other via libcluster reading Zed's cluster
# artifact.

set -eu

POOL="mac_zroot"
JAILS="hello_beam_100 hello_beam_101 hello_beam_102 hello_beam_103 hello_beam_104"
IPS="10.17.89.100 10.17.89.101 10.17.89.102 10.17.89.103 10.17.89.104"
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

    for j in $JAILS; do
        full="$POOL/jails/$j"
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

    # All 5 jails exist + running
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

    # Cluster artifact on host + inside each jail
    artifact="/var/db/zed/cluster/demo.config"
    if doas test -f "$artifact"; then
        count=$(doas wc -l <"$artifact" | tr -d ' ')
        log "  [OK] cluster artifact on host ($count lines)"
    else
        log "  [FAIL] cluster artifact missing on host"
        rc=1
    fi

    for j in $JAILS; do
        if doas bastille cmd "$j" test -f "$artifact" >/dev/null 2>&1; then
            log "  [OK] artifact visible inside $j (nullfs mount)"
        else
            log "  [FAIL] artifact not visible inside $j"
            rc=1
        fi
    done

    # epmd reachable from host for every jail
    for ip in $IPS; do
        if nc -z -w 3 "$ip" 4369 2>/dev/null; then
            log "  [OK] epmd on $ip:4369 reachable"
        else
            log "  [FAIL] epmd on $ip:4369 not reachable"
            rc=1
        fi
    done

    # All 5 BEAM nodes registered with their jailed epmd
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

    # Cluster proof: from a host verify BEAM connected to node .100,
    # Node.list should include the other 4. Requires SMOKE_COOKIE.
    if [ -n "${SMOKE_COOKIE:-}" ]; then
        peers=$(cd ~/zed && env SMOKE_COOKIE="${SMOKE_COOKIE}" \
            elixir --erl "-name verify@127.0.0.1 -setcookie ${SMOKE_COOKIE}" \
                   -S mix run -e '
                     target = :"hello_beam@10.17.89.100"
                     case :net_adm.ping(target) do
                       :pong ->
                         peers = :rpc.call(target, Node, :list, [])
                         IO.puts("__PEERS__" <> inspect(peers))
                       other ->
                         IO.puts("__PEERS__ping_failed:" <> inspect(other))
                     end
                   ' 2>&1 | grep "__PEERS__" | sed "s/__PEERS__//")

        # Expect the other 4 hello_beam nodes visible in Node.list
        expected_count=0
        for ip in 10.17.89.101 10.17.89.102 10.17.89.103 10.17.89.104; do
            if echo "$peers" | grep -q "hello_beam@$ip"; then
                expected_count=$((expected_count + 1))
            fi
        done

        if [ $expected_count -eq 4 ]; then
            log "  [OK] node .100 sees all other 4 nodes in Node.list"
        else
            log "  [FAIL] node .100 sees only $expected_count of 4 peers (${peers})"
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
