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

    # Prime doas up-front (stderr on stdout so prompts are visible).
    log "priming doas (enter password if prompted)"
    doas true

    for j in $JAILS; do
        if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "$j"; then
            log "  destroying jail $j"
            doas bastille destroy -a -f "$j" || true
        else
            log "  jail $j not present"
        fi
    done

    for d in $DATASETS; do
        full="$POOL/$d"
        # zfs list to stderr on missing dataset is expected — swallow
        # ONLY that stderr, not doas's, by using a check that always
        # returns cleanly and doesn't ask for reauth.
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

    # Prime doas up-front so any password prompt appears here, not
    # buried inside a check with stderr redirected. Every subsequent
    # doas call in this session reuses the auth cache.
    log "priming doas (enter password if prompted)"
    doas true

    rc=0

    # `bastille cmd <jail> foo` prints "Jail is not running" to stdout
    # and STILL EXITS 0. Every jail-internal check would false-positive
    # on a stopped jail. Guard by requiring `jls -j <name>` to succeed
    # (kernel-level running check) before treating a bastille cmd's
    # exit code as meaningful.
    jail_running() { doas jls -j "$1" -q jid >/dev/null 2>&1; }

    # Each check: stdout redirected to /dev/null for cleanliness;
    # stderr LEFT ATTACHED so any doas re-prompt or unexpected error
    # is visible.
    for j in $JAILS; do
        if doas bastille list >/dev/null; then
            if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "$j"; then
                log "  [OK] jail $j exists"
            else
                log "  [FAIL] jail $j missing"
                rc=1
            fi
        fi
    done

    # jail_param passthrough
    if doas grep -q "allow.sysvipc" /usr/local/bastille/jails/pg/jail.conf; then
        log "  [OK] pg jail.conf has allow.sysvipc"
    else
        log "  [FAIL] pg jail.conf missing allow.sysvipc"
        rc=1
    fi

    if doas grep -q "allow.raw_sockets" /usr/local/bastille/jails/ch/jail.conf; then
        log "  [OK] ch jail.conf has allow.raw_sockets"
    else
        log "  [FAIL] ch jail.conf missing allow.raw_sockets"
        rc=1
    fi

    # Data volumes mounted into jails — mount(8) is unprivileged
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

    # Jail runtime state (kernel-level)
    for j in $JAILS; do
        if jail_running "$j"; then
            log "  [OK] jail $j is running"
        else
            log "  [FAIL] jail $j is NOT running"
            rc=1
        fi
    done

    # Packages inside jails — guarded on running
    if jail_running pg && doas bastille cmd pg which pg_ctl >/dev/null; then
        log "  [OK] pg has postgresql16-server (pg_ctl found)"
    else
        log "  [FAIL] pg missing postgresql16-server or jail not running"
        rc=1
    fi

    if jail_running ch && doas bastille cmd ch which clickhouse-server >/dev/null; then
        log "  [OK] ch has clickhouse (server binary found)"
    else
        log "  [FAIL] ch missing clickhouse or jail not running"
        rc=1
    fi

    # Setup markers — guarded
    if jail_running pg && doas bastille cmd pg test -f /var/db/postgres/16/data/PG_VERSION; then
        log "  [OK] pg initdb ran (PG_VERSION exists)"
    else
        log "  [FAIL] pg initdb did not run or jail not running"
        rc=1
    fi

    if jail_running pg && doas bastille cmd pg grep -q "10.17.89.0/24" /var/db/postgres/16/data/pg_hba.conf; then
        log "  [OK] pg pg_hba.conf has bastille0 subnet"
    else
        log "  [FAIL] pg pg_hba.conf missing bastille0 subnet or jail not running"
        rc=1
    fi

    # CH XML overlays — filesystem check, no doas needed if world-readable;
    # switch to doas ls if it isn't
    for f in logs.xml ipv4-only.xml low-resources.xml; do
        if doas test -f "/usr/local/bastille/jails/ch/root/usr/local/etc/clickhouse-server/config.d/$f"; then
            log "  [OK] ch config.d/$f present"
        else
            log "  [FAIL] ch config.d/$f missing"
            rc=1
        fi
    done

    # Services running — guarded
    if jail_running pg && doas bastille cmd pg service postgresql status >/dev/null; then
        log "  [OK] postgresql running in pg jail"
    else
        log "  [FAIL] postgresql not running in pg jail (or jail down)"
        rc=1
    fi

    if jail_running ch && doas bastille cmd ch service clickhouse status >/dev/null; then
        log "  [OK] clickhouse running in ch jail"
    else
        log "  [FAIL] clickhouse not running in ch jail (or jail down)"
        rc=1
    fi

    # End-to-end
    if jail_running pg && doas bastille cmd pg su -m postgres -c "psql -c 'SELECT version()'" | grep -q PostgreSQL; then
        log "  [OK] pg accepts psql connections locally"
    else
        log "  [FAIL] pg not responding to psql (or jail down)"
        rc=1
    fi

    if jail_running ch && doas bastille cmd ch fetch -qo - "http://127.0.0.1:8123/ping" | grep -qi ok; then
        log "  [OK] ch HTTP endpoint returns Ok"
    else
        log "  [FAIL] ch HTTP endpoint not responding (or jail down)"
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
