#!/bin/sh
# verify-bastille-host.sh — readiness check for an A5 zed-host (FreeBSD).
#
# Run as the unprivileged user (e.g. `io`); the smoke test requires `doas`.
# Non-destructive by default. Pass `--smoke` to additionally create and
# destroy a temporary `verify-sandbox` jail end-to-end.
#
# Exit codes:
#   0 = ready (or ready-with-caveats)
#   1 = at least one hard failure; do not start A5 work yet.
#
# Usage:
#   sh verify-bastille-host.sh             # quick checks only
#   sh verify-bastille-host.sh --smoke     # full path incl jail create/destroy

set -u

if [ -t 1 ]; then
    GREEN=$(tput setaf 2 2>/dev/null || printf '')
    RED=$(tput setaf 1 2>/dev/null || printf '')
    YELLOW=$(tput setaf 3 2>/dev/null || printf '')
    BOLD=$(tput bold 2>/dev/null || printf '')
    RESET=$(tput sgr0 2>/dev/null || printf '')
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; RESET=""
fi

PASS=0
FAIL=0
WARN=0

ok()   { printf "  %s✓%s %s\n" "$GREEN" "$RESET" "$1"; PASS=$((PASS + 1)); }
bad()  { printf "  %s✗%s %s\n" "$RED"   "$RESET" "$1"; FAIL=$((FAIL + 1)); }
warn() { printf "  %s!%s %s\n" "$YELLOW" "$RESET" "$1"; WARN=$((WARN + 1)); }
hdr()  { printf "\n%s== %s ==%s\n" "$BOLD" "$1" "$RESET"; }

# ----------------------------------------------------------------------
hdr "FreeBSD version"

KREL=$(freebsd-version -k 2>/dev/null || printf '?')
UREL=$(freebsd-version -u 2>/dev/null || printf '?')

case "$KREL" in
    15.*) ok "kernel $KREL" ;;
    14.*) warn "kernel $KREL — supported but A5 targets 15.x" ;;
    *)    bad  "kernel $KREL — A5 plan assumes 14.x or 15.x" ;;
esac

if [ "$KREL" = "$UREL" ]; then
    ok "userland matches kernel"
else
    warn "userland $UREL differs from kernel $KREL"
fi

# ----------------------------------------------------------------------
hdr "doas"

if command -v doas >/dev/null 2>&1; then
    ok "doas installed"
else
    bad "doas missing — pkg install -y doas"
fi

if [ -r /usr/local/etc/doas.conf ]; then
    ok "/usr/local/etc/doas.conf readable"
else
    warn "/usr/local/etc/doas.conf not readable from $(id -un) (expected if you're not in wheel)"
fi

# ----------------------------------------------------------------------
hdr "Bastille"

if command -v bastille >/dev/null 2>&1; then
    BVER=$(pkg info -E bastille 2>/dev/null | head -1)
    ok "bastille installed: $BVER"
else
    bad "bastille not installed — pkg install -y bastille"
fi

if [ -r /usr/local/etc/bastille/bastille.conf ]; then
    ok "/usr/local/etc/bastille/bastille.conf exists"
else
    warn "/usr/local/etc/bastille/bastille.conf missing"
fi

# sysrc -f handles shell-quoted values and strips inline comments
# reliably; grep + cut broke on lines like
#   bastille_zfs_enable="YES"  ## default: "NO"
# which leaked the comment into the captured value.
ZFSEN=$(sysrc -f /usr/local/etc/bastille/bastille.conf -n bastille_zfs_enable 2>/dev/null || printf '')
ZPOOL=$(sysrc -f /usr/local/etc/bastille/bastille.conf -n bastille_zfs_zpool 2>/dev/null || printf '')

case "$ZFSEN" in
    YES|yes)
        ok "bastille ZFS backend enabled"
        if [ -n "$ZPOOL" ] && zpool list -H -o name 2>/dev/null | grep -qx "$ZPOOL"; then
            ok "bastille_zfs_zpool=$ZPOOL exists"
        else
            bad "bastille_zfs_zpool=$ZPOOL not found in zpool list"
        fi
        ;;
    *)
        warn "bastille ZFS backend not enabled — UFS fallback in use"
        ;;
esac

# ----------------------------------------------------------------------
hdr "rc.conf flags"

bastille_enable=$(sysrc -n bastille_enable 2>/dev/null || printf '')
case "$bastille_enable" in
    YES) ok "bastille_enable=YES" ;;
    *)   warn "bastille_enable not YES — jails won't autostart on reboot" ;;
esac

gateway_enable=$(sysrc -n gateway_enable 2>/dev/null || printf '')
case "$gateway_enable" in
    YES) ok "gateway_enable=YES" ;;
    *)   warn "gateway_enable not YES — jails won't NAT outward without manual setup" ;;
esac

cloned_ifs=$(sysrc -n cloned_interfaces 2>/dev/null || printf '')
case "$cloned_ifs" in
    *bastille0*) ok "cloned_interfaces includes bastille0" ;;
    *)           warn "cloned_interfaces missing bastille0 — won't persist over reboot" ;;
esac

# ----------------------------------------------------------------------
hdr "kernel state"

FWD=$(sysctl -n net.inet.ip.forwarding 2>/dev/null)
case "$FWD" in
    1) ok "net.inet.ip.forwarding=1" ;;
    *) bad "net.inet.ip.forwarding=$FWD — jails can't reach outside" ;;
esac

# pf is required for Bastille's rdr/NAT paths. Bastille itself runs
# jails without it (shared-IP mode), but A5.2's port-forwarding work
# and anything beyond a loopback address needs /dev/pf reachable.
if kldstat -q -n pf.ko 2>/dev/null; then
    ok "pf kernel module loaded"
else
    warn "pf kernel module not loaded — doas kldload pf; doas sysrc pf_load=YES"
fi

if [ -c /dev/pf ]; then
    ok "/dev/pf present"
else
    warn "/dev/pf absent — bastille rdr/NAT will fail silently"
fi

# ----------------------------------------------------------------------
hdr "bastille0 interface"

if ifconfig bastille0 >/dev/null 2>&1; then
    ok "bastille0 exists"
    MTU=$(ifconfig bastille0 2>/dev/null | awk '/mtu/{print $NF; exit}')
    case "$MTU" in
        16384) ok "bastille0 mtu 16384 (loopback)" ;;
        *)     warn "bastille0 mtu=$MTU (expected 16384 for lo-style iface)" ;;
    esac
    if ifconfig bastille0 2>/dev/null | grep -q 'flags=.*LOOPBACK'; then
        ok "bastille0 has LOOPBACK flag"
    else
        warn "bastille0 missing LOOPBACK flag — was it created via 'ifconfig lo1 create name bastille0'?"
    fi
else
    bad "bastille0 missing — doas ifconfig lo1 create name bastille0; doas sysrc cloned_interfaces+=bastille0"
fi

# ----------------------------------------------------------------------
hdr "supporting tools"

for cmd in tmux git openssl; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd present"
    else
        warn "$cmd not in PATH (pkg install -y $cmd)"
    fi
done

# Elixir is optional — only needed if you author/test on the host directly.
if command -v elixir >/dev/null 2>&1; then
    ok "elixir present ($(elixir --version 2>/dev/null | tail -1))"
else
    warn "elixir not in PATH (optional — only needed if running zed test suite on this host)"
fi

# ----------------------------------------------------------------------
hdr "Bastille release cache"

if [ -d /usr/local/bastille/releases/15.0-RELEASE ]; then
    ok "15.0-RELEASE bootstrapped"
elif [ -d /usr/local/bastille/releases/14.2-RELEASE ]; then
    warn "14.2-RELEASE present but no 15.0-RELEASE — A5 plan targets 15.x"
else
    bad "no FreeBSD release bootstrapped — doas bastille bootstrap 15.0-RELEASE update"
fi

# ----------------------------------------------------------------------
# Optional: full create/start/cmd/stop/destroy round-trip.
# Side effects are bounded: creates and tears down a single jail named
# 'verify-sandbox' on 10.17.89.249/24. /tmp/verify-bastille-host.log
# captures bastille's output for diagnosis.
case "${1:-}" in
    --smoke|--full)
        hdr "smoke test (creates + destroys 'verify-sandbox')"

        SANDBOX=verify-sandbox
        LOG=/tmp/verify-bastille-host.log
        : > "$LOG"

        # If a stale jail with this name exists from a prior aborted run,
        # nuke it so the create call has a clean slate. Detection by
        # filesystem presence is more reliable than parsing
        # `bastille list` columns across versions.
        if [ -d "/usr/local/bastille/jails/$SANDBOX" ]; then
            warn "stale '$SANDBOX' present, destroying first"
            doas bastille stop "$SANDBOX" >>"$LOG" 2>&1 || true
            doas bastille destroy -af "$SANDBOX" >>"$LOG" 2>&1 || true
            doas rm -rf "/usr/local/bastille/jails/$SANDBOX" >>"$LOG" 2>&1 || true
        fi

        if doas bastille create "$SANDBOX" 15.0-RELEASE 10.17.89.249/24 >>"$LOG" 2>&1; then
            ok "create"

            if doas bastille start "$SANDBOX" >>"$LOG" 2>&1; then
                ok "start"

                if doas bastille cmd "$SANDBOX" uname -a >>"$LOG" 2>&1; then
                    ok "cmd uname -a"
                else
                    bad "cmd failed (see $LOG)"
                fi

                doas bastille stop "$SANDBOX" >>"$LOG" 2>&1 \
                    && ok "stop" \
                    || bad "stop failed (see $LOG)"
            else
                bad "start failed (see $LOG)"
            fi

            # -a = auto-confirm, -f = force stop-before-destroy. Without -a,
            # bastille still prints "Are you sure? [y|n]" and waits for
            # stdin, which the script does not provide.
            if doas bastille destroy -af "$SANDBOX" >>"$LOG" 2>&1; then
                ok "destroy"
            else
                bad "destroy failed (see $LOG) — manual cleanup may be required"
            fi
        else
            bad "create failed (see $LOG)"
        fi
        ;;
    "")
        hdr "smoke test"
        warn "skipped (run with --smoke to create+destroy a verify-sandbox jail)"
        ;;
    *)
        printf "\nunknown argument: %s\nusage: %s [--smoke]\n" "$1" "$0" >&2
        exit 2
        ;;
esac

# ----------------------------------------------------------------------
hdr "summary"

printf "  %s%d pass%s, %s%d warn%s, %s%d fail%s\n" \
    "$GREEN" "$PASS" "$RESET" \
    "$YELLOW" "$WARN" "$RESET" \
    "$RED" "$FAIL" "$RESET"

printf "\n"
if [ "$FAIL" -gt 0 ]; then
    printf "%sNOT READY%s — resolve failures before kicking off A5 integration.\n" "$RED" "$RESET"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    printf "%sREADY WITH CAVEATS%s — review warnings; A5 unit tests OK to run.\n" "$YELLOW" "$RESET"
    exit 0
else
    printf "%sREADY%s — A5 host complete.\n" "$GREEN" "$RESET"
    exit 0
fi
