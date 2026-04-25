#!/bin/sh
# demo-ch-bootstrap.sh — Bootstrap the ClickHouse jail for the demo cluster.
#
# Intended to be run by the operator (as `io` with doas) during S6.
# Idempotent: re-running after a partial failure should be safe.
#
# Prerequisites:
#   - bastille installed, 15.0-RELEASE bootstrapped
#   - bastille0 interface up
#   - ZFS dataset zroot_mac/data/ch created by zed converge
#   - Plausible config snippets in scripts/clickhouse-config/
#
# Usage:
#   doas sh scripts/demo-ch-bootstrap.sh

set -eu

JAIL=ch
IP="10.17.89.21/24"
RELEASE="15.0-RELEASE"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CH_CONFIG_SRC="${SCRIPT_DIR}/clickhouse-config"
CH_CONFIG_DST="/usr/local/etc/clickhouse-server"

echo "==> Creating jail: ${JAIL}"
if bastille list | grep -q "^${JAIL}\$"; then
    echo "    jail ${JAIL} already exists, skipping create"
else
    bastille create "${JAIL}" "${RELEASE}" "${IP}"
fi

echo "==> Starting jail: ${JAIL}"
bastille start "${JAIL}" || true

echo "==> Installing clickhouse"
bastille pkg "${JAIL}" install -y clickhouse

echo "==> Deploying Plausible ClickHouse config overrides"
# Ensure config directories exist inside the jail
bastille cmd "${JAIL}" mkdir -p "${CH_CONFIG_DST}/config.d"
bastille cmd "${JAIL}" mkdir -p "${CH_CONFIG_DST}/users.d"

# Copy the four Plausible XML snippets
bastille cp "${JAIL}" "${CH_CONFIG_SRC}/logs.xml" \
    "${CH_CONFIG_DST}/config.d/logs.xml"
bastille cp "${JAIL}" "${CH_CONFIG_SRC}/ipv4-only.xml" \
    "${CH_CONFIG_DST}/config.d/ipv4-only.xml"
bastille cp "${JAIL}" "${CH_CONFIG_SRC}/low-resources.xml" \
    "${CH_CONFIG_DST}/config.d/low-resources.xml"
bastille cp "${JAIL}" "${CH_CONFIG_SRC}/default-profile-low-resources-overrides.xml" \
    "${CH_CONFIG_DST}/users.d/default-profile-low-resources-overrides.xml"

echo "==> Enabling clickhouse service"
sysrc -j "${JAIL}" clickhouse_enable=YES

echo "==> Starting clickhouse"
bastille service "${JAIL}" clickhouse start

echo "==> Waiting for ClickHouse to accept connections"
RETRIES=10
while [ "${RETRIES}" -gt 0 ]; do
    if bastille cmd "${JAIL}" fetch -qo - "http://127.0.0.1:8123/ping" 2>/dev/null | grep -q "Ok"; then
        echo "    ClickHouse is up"
        break
    fi
    RETRIES=$((RETRIES - 1))
    echo "    waiting... (${RETRIES} retries left)"
    sleep 2
done

if [ "${RETRIES}" -eq 0 ]; then
    echo "    WARNING: ClickHouse did not respond to /ping within timeout"
    echo "    Check: bastille cmd ${JAIL} cat /var/log/clickhouse-server/clickhouse-server.err.log"
fi

echo "==> Creating plausible_events_db database"
bastille cmd "${JAIL}" clickhouse-client \
    --query "CREATE DATABASE IF NOT EXISTS plausible_events_db"

echo "==> ch jail bootstrap complete"
echo "    Jail IP:   10.17.89.21"
echo "    HTTP port: 8123 (health: http://10.17.89.21:8123/ping)"
echo "    Database:  plausible_events_db"
