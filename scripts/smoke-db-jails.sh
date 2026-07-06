#!/bin/sh
# scripts/smoke-db-jails.sh — verify + cleanup for the DB-jails demo
# (Zed.Examples.DemoDbJails). Replaces demo-pg-bootstrap.sh + demo-ch-
# bootstrap.sh in the "did it work" post-hoc sense.
#
# Intended host: mac-248 (FreeBSD 15, pool mac_zroot, bastille0 subnet
# 10.17.89.0/24, doas rules in place).
#
# Usage:
#   sh scripts/smoke-db-jails.sh clean    # tear down datasets + jails
#   sh scripts/smoke-db-jails.sh verify   # assert expected state
#   sh scripts/smoke-db-jails.sh full     # clean, converge, verify, converge, verify
#
# Converge itself runs from iex:
#   doas iex --sname db --cookie exmc -S mix
#   iex> Zed.Examples.DemoDbJails.converge() |> IO.inspect(limit: :infinity)

set -eu

POOL="mac_zroot"
JAILS="pg ch"
DATASETS="jails/pg data/pg jails/ch data/ch"

log() { printf '=== %s ===\n' "$*"; }

clean() {
    log "clean: destroying jails + datasets (idempotent)"

    for j in $JAILS; do
        if doas bastille list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$j"; then
            log "  destroying jail $j"
            doas bastille destroy -a -f "$j" || true
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

verify() {
    log "verify: asserting expected converged state"

    rc=0

    for j in $JAILS; do
        if doas bastille list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$j"; then
            log "  [OK] jail $j exists"
        else
            log "  [FAIL] jail $j missing"
            rc=1
        fi
    done

    # jail_param passthrough
    if doas grep -q "allow.sysvipc" /usr/local/bastille/jails/pg/jail.conf 2>/dev/null; then
        log "  [OK] pg jail.conf has allow.sysvipc"
    else
        log "  [FAIL] pg jail.conf missing allow.sysvipc"
        rc=1
    fi

    if doas grep -q "allow.raw_sockets" /usr/local/bastille/jails/ch/jail.conf 2>/dev/null; then
        log "  [OK] ch jail.conf has allow.raw_sockets"
    else
        log "  [FAIL] ch jail.conf missing allow.raw_sockets"
        rc=1
    fi

    # Data volumes mounted into jails
    if mount | grep -q " on /usr/local/bastille/jails/pg/root/var/db/postgres "; then
        log "  [OK] pg data volume nullfs-mounted"
    else
        log "  [FAIL] pg data volume not mounted"
        rc=1
    fi

    if mount | grep -q " on /usr/local/bastille/jails/ch/root/var/lib/clickhouse "; then
        log "  [OK] ch data volume nullfs-mounted"
    else
        log "  [FAIL] ch data volume not mounted"
        rc=1
    fi

    # Packages inside jails
    if doas bastille cmd pg which pg_ctl >/dev/null 2>&1; then
        log "  [OK] pg has postgresql16-server (pg_ctl found)"
    else
        log "  [FAIL] pg missing postgresql16-server"
        rc=1
    fi

    if doas bastille cmd ch which clickhouse-server >/dev/null 2>&1; then
        log "  [OK] ch has clickhouse (server binary found)"
    else
        log "  [FAIL] ch missing clickhouse"
        rc=1
    fi

    # Setup markers
    if doas bastille cmd pg test -f /var/db/postgres/16/data/PG_VERSION 2>/dev/null; then
        log "  [OK] pg initdb ran (PG_VERSION exists)"
    else
        log "  [FAIL] pg initdb did not run"
        rc=1
    fi

    if doas bastille cmd pg grep -q "10.17.89.0/24" /var/db/postgres/16/data/pg_hba.conf 2>/dev/null; then
        log "  [OK] pg pg_hba.conf has bastille0 subnet"
    else
        log "  [FAIL] pg pg_hba.conf missing bastille0 subnet"
        rc=1
    fi

    # CH XML overlays
    for f in logs.xml ipv4-only.xml low-resources.xml; do
        if [ -f "/usr/local/bastille/jails/ch/root/usr/local/etc/clickhouse-server/config.d/$f" ]; then
            log "  [OK] ch config.d/$f present"
        else
            log "  [FAIL] ch config.d/$f missing"
            rc=1
        fi
    done

    # Services running
    if doas bastille cmd pg service postgresql status >/dev/null 2>&1; then
        log "  [OK] postgresql running in pg jail"
    else
        log "  [FAIL] postgresql not running in pg jail"
        rc=1
    fi

    if doas bastille cmd ch service clickhouse status >/dev/null 2>&1; then
        log "  [OK] clickhouse running in ch jail"
    else
        log "  [FAIL] clickhouse not running in ch jail"
        rc=1
    fi

    # End-to-end: can we actually talk to them?
    if doas bastille cmd pg su -m postgres -c "psql -c 'SELECT version()'" 2>/dev/null | grep -q PostgreSQL; then
        log "  [OK] pg accepts psql connections locally"
    else
        log "  [FAIL] pg not responding to psql"
        rc=1
    fi

    if doas bastille cmd ch fetch -qo - "http://127.0.0.1:8123/ping" 2>/dev/null | grep -qi ok; then
        log "  [OK] ch HTTP endpoint returns Ok"
    else
        log "  [FAIL] ch HTTP endpoint not responding"
        rc=1
    fi

    if [ $rc -eq 0 ]; then
        log "verify: PASS"
    else
        log "verify: FAIL"
    fi

    return $rc
}

pause_for_converge() {
    log "Run in another terminal (or the same one):"
    echo
    echo "    cd ~/zed"
    echo "    doas iex --sname db --cookie exmc -S mix"
    echo "    iex> Zed.Examples.DemoDbJails.converge() |> IO.inspect(limit: :infinity)"
    echo
    printf 'Press ENTER when converge is done: '
    read _
}

full() {
    clean
    pause_for_converge
    log "verify after first converge"
    verify
    log "run converge AGAIN (should be all no-op / already-present)"
    pause_for_converge
    log "verify after second converge (idempotency check)"
    verify
}

case "${1:-verify}" in
    clean)  clean ;;
    verify) verify ;;
    full)   full ;;
    *)      echo "usage: $0 {clean|verify|full}"; exit 1 ;;
esac
