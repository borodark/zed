#!/bin/sh
# scripts/smoke-contained-real-app.sh — clean + verify for the
# Path C3 smoke (Zed.Examples.SmokeContainedRealApp).
#
# Intended host: mac-248 (FreeBSD 15, pool mac_zroot, bastille0 subnet
# 10.17.89.0/24, doas rules in place, hello_beam release built via
# `sh scripts/build-real-release.sh`).

set -eu

POOL="mac_zroot"
JAIL="hello_beam_jail"
DATASETS="jails/hello_beam_jail"
APP="hello_beam"

log() { printf '=== %s ===\n' "$*"; }

clean() {
    log "clean: destroying jail + dataset (idempotent)"

    log "priming doas (enter password if prompted)"
    doas true

    if doas bastille list | awk 'NR>1 {print $2}' | grep -qx "${JAIL}"; then
        log "  destroying jail ${JAIL}"
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

    # Release deployed
    version_dir="/usr/local/bastille/jails/${JAIL}/root/opt/${APP}/releases/0.1.0"
    if doas test -d "${version_dir}"; then
        log "  [OK] release extracted at /opt/${APP}/releases/0.1.0"
    else
        log "  [FAIL] release not found at expected version dir"
        rc=1
    fi

    # Env file written by :jail_app :deploy
    env_file="/usr/local/bastille/jails/${JAIL}/root/var/db/zed/${APP}.env"
    if doas test -f "${env_file}"; then
        log "  [OK] env file written at /var/db/zed/${APP}.env"

        # Content probe — must be exported so mix release's bin/<app>
        # child inherits them, plus RELEASE_DISTRIBUTION to enable
        # net_kernel.
        if doas grep -q '^export RELEASE_NODE=' "${env_file}" && \
           doas grep -q '^export RELEASE_COOKIE=' "${env_file}" && \
           doas grep -q '^export RELEASE_DISTRIBUTION=' "${env_file}"; then
            log "  [OK] env file exports RELEASE_DISTRIBUTION + NODE + COOKIE"
        else
            log "  [FAIL] env file missing an exported RELEASE_* var"
            rc=1
        fi

        # Mode 0400
        mode=$(doas stat -f '%Lp' "${env_file}" 2>/dev/null || echo "")
        if [ "${mode}" = "400" ]; then
            log "  [OK] env file mode is 0400"
        else
            log "  [FAIL] env file mode is ${mode}, expected 400"
            rc=1
        fi
    else
        log "  [FAIL] env file not written"
        rc=1
    fi

    # rc.d script
    rc_path="/usr/local/bastille/jails/${JAIL}/root/usr/local/etc/rc.d/${APP}"
    if doas test -x "${rc_path}"; then
        log "  [OK] rc.d script installed inside jail"
    else
        log "  [FAIL] rc.d script missing inside jail"
        rc=1
    fi

    # BEAM process running — mix release's `daemon` runner via
    # `run_erl` doesn't write a shell pidfile. Ask epmd for the
    # registered node list; a properly distributed release shows up.
    if jail_running "${JAIL}" && \
       doas bastille cmd "${JAIL}" /opt/${APP}/current/erts-*/bin/epmd -names 2>/dev/null | \
       grep -q "name ${APP} at port"; then
        log "  [OK] BEAM node ${APP} registered with epmd inside jail"
    else
        log "  [FAIL] BEAM node ${APP} not registered with epmd"
        rc=1
    fi

    # epmd on 4369
    if nc -z -w 3 10.17.89.93 4369 2>/dev/null; then
        log "  [OK] epmd on 10.17.89.93:4369 reachable"
    else
        log "  [FAIL] epmd on 10.17.89.93:4369 not reachable"
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
