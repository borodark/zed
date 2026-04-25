#!/bin/sh
# scripts/host-bring-up.sh — idempotent FreeBSD host preparation for a
# zed deploy (A5a.3). Run once as root; safe to re-run.
#
# Brings up everything zed assumes about the host:
#
#   1. zedweb / zedops service users (uid 8501 / 8502)
#   2. bastille0 cloned interface, persistent across reboot
#   3. pf module loaded + enabled, /etc/pf.conf in place
#   4. IPv4 forwarding on
#   5. capability-scoped doas.conf installed (docs/doas.conf.zedops)
#   6. bastille pkg + sysrc enable
#   7. /var/db/zed audit log directory, owned by zedops
#
# Pass --strict to remove the operator wheel-doas rule (post-A5a
# production posture). Default leaves it in place for ergonomic
# debugging.
#
# This script supersedes ad-hoc README "and then you run …" steps.
# `verify-bastille-host.sh` re-checks the same assertions and tells
# you which step failed if a re-run did nothing.
#
# Exit codes:
#   0 — all assertions either already true or made true
#   1 — at least one step failed; see stderr
#   2 — invalid argument

set -eu

STRICT=0
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" != "0" ]; then
    printf 'must run as root (uid 0); got uid=%s\n' "$(id -u)" >&2
    exit 1
fi

# Resolve script + repo paths so the doas/pf templates are found
# regardless of CWD.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

step() { printf '\n[%s]\n' "$1"; }
ok()   { printf '  ok: %s\n' "$1"; }
note() { printf '  note: %s\n' "$1"; }
bad()  { printf '  FAIL: %s\n' "$1" >&2; exit 1; }

# ----------------------------------------------------------------------
step "1. service users"

if pw groupshow zedweb >/dev/null 2>&1; then
    ok "group zedweb already exists"
else
    pw groupadd zedweb -g 8501
    ok "created group zedweb (gid 8501)"
fi

if pw groupshow zedops >/dev/null 2>&1; then
    ok "group zedops already exists"
else
    pw groupadd zedops -g 8502
    ok "created group zedops (gid 8502)"
fi

if pw usershow zedweb >/dev/null 2>&1; then
    ok "user zedweb already exists"
else
    pw useradd zedweb -u 8501 -g zedweb -G zedweb \
        -s /usr/sbin/nologin -d /var/db/zed/web -m \
        -c "zed web (LiveView, no privilege)"
    ok "created user zedweb (uid 8501, no shell)"
fi

if pw usershow zedops >/dev/null 2>&1; then
    ok "user zedops already exists"
else
    # zedops is also in the zedweb group so it can chown shared
    # bits (audit log directory, socket parent) for zedweb to read.
    pw useradd zedops -u 8502 -g zedops -G zedops,zedweb \
        -s /usr/sbin/nologin -d /var/db/zed/ops -m \
        -c "zed ops (privileged converge engine)"
    ok "created user zedops (uid 8502, no shell)"
fi

# ----------------------------------------------------------------------
step "2. bastille0 cloned interface"

if ! grep -q '^cloned_interfaces=' /etc/rc.conf 2>/dev/null; then
    sysrc cloned_interfaces+=bastille0 >/dev/null
    ok "added bastille0 to cloned_interfaces"
elif ! sysrc -n cloned_interfaces | grep -qw bastille0; then
    sysrc cloned_interfaces+=bastille0 >/dev/null
    ok "appended bastille0 to existing cloned_interfaces"
else
    ok "cloned_interfaces already includes bastille0"
fi

if ifconfig bastille0 >/dev/null 2>&1; then
    ok "bastille0 interface up"
else
    ifconfig lo1 create name bastille0
    ok "created bastille0"
fi

# ----------------------------------------------------------------------
step "3. pf"

sysrc kld_list+=pf >/dev/null 2>&1 || true
sysrc pf_enable=YES >/dev/null
sysrc pflog_enable=YES >/dev/null
sysrc pf_load=YES >/dev/null

if kldstat -q -n pf.ko; then
    ok "pf module loaded"
else
    kldload pf
    ok "loaded pf module"
fi

if [ -f /etc/pf.conf ]; then
    ok "/etc/pf.conf already present (not replacing)"
    note "to refresh: cp $REPO_DIR/docs/pf.conf /etc/pf.conf"
else
    install -m 0644 -o root -g wheel "$REPO_DIR/docs/pf.conf" /etc/pf.conf
    ok "installed /etc/pf.conf from docs/pf.conf"
fi

if service pf status >/dev/null 2>&1; then
    ok "pf service running"
else
    service pf start >/dev/null 2>&1 || note "pf service not started (may need /etc/pf.conf review)"
fi

# ----------------------------------------------------------------------
step "4. IPv4 forwarding"

sysrc gateway_enable=YES >/dev/null

if [ "$(sysctl -n net.inet.ip.forwarding)" = "1" ]; then
    ok "net.inet.ip.forwarding already 1"
else
    sysctl net.inet.ip.forwarding=1 >/dev/null
    ok "enabled net.inet.ip.forwarding"
fi

# ----------------------------------------------------------------------
step "5. doas rules"

DOAS_SRC="$REPO_DIR/docs/doas.conf.zedops"
DOAS_DST="/usr/local/etc/doas.conf"

if [ ! -f "$DOAS_SRC" ]; then
    bad "missing $DOAS_SRC — repo checkout incomplete?"
fi

# Strict mode strips the wheel rule; default keeps it in for operator
# debugging. We compose the file in-memory then write atomically so a
# crashed mid-write doesn't lock anyone out.
TMP_DOAS=$(mktemp -t zed-doas)
trap 'rm -f "$TMP_DOAS"' EXIT

if [ "$STRICT" = "1" ]; then
    # Drop the `permit persist :wheel` block (4 lines including comment).
    awk '
        /^permit persist :wheel/ { skip=1; next }
        skip && /^[[:space:]]*$/ { skip=0; next }
        !skip { print }
    ' "$DOAS_SRC" > "$TMP_DOAS"
    note "strict mode: removed operator wheel-doas rule"
else
    cp "$DOAS_SRC" "$TMP_DOAS"
fi

# doas requires a trailing newline. printf to be sure.
[ -z "$(tail -c1 "$TMP_DOAS")" ] || printf '\n' >> "$TMP_DOAS"

# Validate before installing — `doas -C` parses without applying.
if doas -C "$TMP_DOAS" 2>/dev/null; then
    ok "doas.conf parses"
else
    bad "doas -C rejected the rendered config"
fi

if [ -f "$DOAS_DST" ] && cmp -s "$TMP_DOAS" "$DOAS_DST"; then
    ok "$DOAS_DST already up-to-date"
else
    install -m 0600 -o root -g wheel "$TMP_DOAS" "$DOAS_DST"
    ok "installed $DOAS_DST"
fi

# ----------------------------------------------------------------------
step "6. bastille"

if pkg query %n bastille >/dev/null 2>&1; then
    ok "bastille pkg already installed: $(pkg info -E bastille | head -1)"
else
    env ASSUME_ALWAYS_YES=YES pkg install -y bastille
    ok "installed bastille pkg"
fi

sysrc bastille_enable=YES >/dev/null
sysrc bastille_zfs_enable=YES >/dev/null

if [ -n "${ZED_BASTILLE_ZPOOL:-}" ]; then
    sysrc bastille_zfs_zpool="$ZED_BASTILLE_ZPOOL" >/dev/null
    ok "bastille_zfs_zpool=$ZED_BASTILLE_ZPOOL"
else
    CURRENT_POOL=$(sysrc -n bastille_zfs_zpool 2>/dev/null || printf '')
    if [ -z "$CURRENT_POOL" ]; then
        note "ZED_BASTILLE_ZPOOL not set and bastille_zfs_zpool unset — set it before first jail create"
    else
        ok "bastille_zfs_zpool=$CURRENT_POOL (unchanged)"
    fi
fi

# ----------------------------------------------------------------------
step "7. audit log directory"

install -d -o zedops -g zedops -m 0700 /var/db/zed
install -d -o zedops -g zedops -m 0700 /var/db/zed/audit
install -d -o zedops -g zedops -m 0700 /var/db/zed/ops
install -d -o zedweb -g zedweb -m 0700 /var/db/zed/web
ok "/var/db/zed tree owned by zedops/zedweb"

# Socket parent directory; zedops writes the socket on start.
install -d -o zedops -g zedweb -m 0750 /var/run/zed
ok "/var/run/zed (0750 zedops:zedweb) — socket parent"

# ----------------------------------------------------------------------
printf '\nhost bring-up complete. next steps:\n'
printf '  - run scripts/verify-bastille-host.sh to re-check\n'
printf '  - deploy releases as zedweb (zedweb start) and zedops (zedops start)\n'
