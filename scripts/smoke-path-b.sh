#!/bin/sh
# scripts/smoke-path-b.sh — verify + cleanup helpers for the Path B
# executor smoke test (Zed.Examples.SmokePathB).
#
# Intended host: mac-248 (FreeBSD 15, pool mac_zroot, bastille0 subnet
# 10.17.89.0/24, doas rules for zedops).
#
# Usage:
#   sh scripts/smoke-path-b.sh clean    # tear down datasets + jails
#   sh scripts/smoke-path-b.sh verify   # assert expected state
#   sh scripts/smoke-path-b.sh full     # clean, converge, verify, converge (idempotent), verify
#
# The `converge` step is not shell-driven — run it from iex:
#   iex --sname smoke --cookie exmc -S mix
#   iex> Zed.Examples.SmokePathB.converge()
#
# `full` prompts to run converge between clean and verify so you can
# invoke iex from another terminal.

set -eu

POOL="mac_zroot"
JAILS="smoke_up smoke_down"
DATASETS="jails/smoke_up jails/smoke_down"

log() { printf '=== %s ===\n' "$*"; }

clean() {
    log "clean: destroying jails + datasets (idempotent)"

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
        if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "$j"; then
            log "  [OK] jail $j exists"
        else
            log "  [FAIL] jail $j missing"
            rc=1
        fi
    done

    # jail_param — allow.sysvipc should be in bastille's jail.conf
    if doas grep -q "allow.sysvipc" /usr/local/bastille/jails/smoke_up/jail.conf 2>/dev/null; then
        log "  [OK] smoke_up jail.conf has allow.sysvipc"
    else
        log "  [FAIL] smoke_up jail.conf missing allow.sysvipc"
        rc=1
    fi

    # jail_file — /etc/motd inside the jail
    if doas grep -q "hello from zed" /usr/local/bastille/jails/smoke_up/root/etc/motd 2>/dev/null; then
        log "  [OK] smoke_up /etc/motd written by jail_file"
    else
        log "  [FAIL] smoke_up /etc/motd missing or wrong content"
        rc=1
    fi

    # jail_pkg — curl should be installed inside smoke_up
    if doas bastille cmd smoke_up which curl >/dev/null 2>&1; then
        log "  [OK] curl installed inside smoke_up"
    else
        log "  [FAIL] curl missing inside smoke_up"
        rc=1
    fi

    # jail_mount — /host_tmp should be a mountpoint inside smoke_up
    if doas bastille cmd smoke_up mount | grep -q '/host_tmp'; then
        log "  [OK] /host_tmp mounted inside smoke_up"
    else
        log "  [FAIL] /host_tmp not mounted inside smoke_up"
        rc=1
    fi

    # jail_svc — cron should be running inside smoke_up
    if doas bastille cmd smoke_up service cron status >/dev/null 2>&1; then
        log "  [OK] cron running inside smoke_up"
    else
        log "  [FAIL] cron not running inside smoke_up"
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
    log "Run in another terminal:"
    echo
    echo "    cd ~/zed"
    echo "    iex --sname smoke --cookie exmc -S mix"
    echo "    iex> Zed.Examples.SmokePathB.converge() |> IO.inspect(limit: :infinity)"
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
