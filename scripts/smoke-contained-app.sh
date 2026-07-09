#!/bin/sh
# scripts/smoke-contained-app.sh — clean + verify for the Path C1
# smoke (Zed.Examples.SmokeContainedApp).
#
# Intended host: mac-248 (FreeBSD 15, pool mac_zroot, bastille0 subnet
# 10.17.89.0/24, doas rules in place, tarball staged via
# build-smoke-app-tarball.sh).

set -eu

POOL="mac_zroot"
JAIL="hello_jail"
DATASETS="jails/hello_jail"
APP="hello"

log() { printf '=== %s ===\n' "$*"; }

clean() {
    log "clean: destroying jail + dataset (idempotent)"

    log "priming doas (enter password if prompted)"
    doas true

    if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "${JAIL}"; then
        log "  destroying jail ${JAIL}"
        # `-f` should suppress the "are you sure" prompt but doesn't
        # always. Pipe `yes` so the second confirmation gets an answer.
        yes | doas bastille destroy -a -f "${JAIL}" || true
    else
        log "  jail ${JAIL} not present"
    fi

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

    # Jail exists + running
    if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "${JAIL}"; then
        log "  [OK] jail ${JAIL} exists"
    else
        log "  [FAIL] jail ${JAIL} missing"
        rc=1
    fi

    if jail_running "${JAIL}"; then
        log "  [OK] jail ${JAIL} is running"
    else
        log "  [FAIL] jail ${JAIL} is NOT running"
        rc=1
    fi

    # Release deployed into jail rootfs
    version_dir="/usr/local/bastille/jails/${JAIL}/root/opt/${APP}/releases/0.1.0"
    if doas test -d "${version_dir}"; then
        log "  [OK] release extracted at /opt/${APP}/releases/0.1.0"
    else
        log "  [FAIL] release not found at expected version dir"
        rc=1
    fi

    current="/usr/local/bastille/jails/${JAIL}/root/opt/${APP}/current"
    if doas test -L "${current}"; then
        log "  [OK] /opt/${APP}/current symlink exists"
    else
        log "  [FAIL] /opt/${APP}/current symlink missing"
        rc=1
    fi

    if doas test -x "/usr/local/bastille/jails/${JAIL}/root/opt/${APP}/current/bin/${APP}"; then
        log "  [OK] release bin/${APP} executable inside jail"
    else
        log "  [FAIL] release bin/${APP} missing or not executable"
        rc=1
    fi

    # rc.d script inside jail
    rc_path="/usr/local/bastille/jails/${JAIL}/root/usr/local/etc/rc.d/${APP}"
    if doas test -x "${rc_path}"; then
        log "  [OK] rc.d script installed inside jail"
    else
        log "  [FAIL] rc.d script missing inside jail"
        rc=1
    fi

    # Service enabled via sysrc
    if jail_running "${JAIL}" && doas bastille cmd "${JAIL}" sysrc -n "${APP}_enable" 2>&1 | grep -qi yes; then
        log "  [OK] ${APP}_enable=YES set inside jail"
    else
        log "  [FAIL] ${APP}_enable not set"
        rc=1
    fi

    # Service running
    if jail_running "${JAIL}" && doas bastille cmd "${JAIL}" service "${APP}" status >/dev/null; then
        log "  [OK] service ${APP} running inside jail"
    else
        log "  [FAIL] service ${APP} not running inside jail"
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
