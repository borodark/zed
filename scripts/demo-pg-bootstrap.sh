#!/bin/sh
# demo-pg-bootstrap.sh — Bootstrap the PostgreSQL jail for the demo cluster.
#
# Intended to be run by the operator (as `io` with doas) during S6.
# Idempotent: re-running after a partial failure should be safe.
#
# Prerequisites:
#   - bastille installed, 15.0-RELEASE bootstrapped
#   - bastille0 interface up
#   - ZFS dataset zroot_mac/data/pg created by zed converge
#
# Usage:
#   doas sh scripts/demo-pg-bootstrap.sh

set -eu

JAIL=pg
IP="10.17.89.20/24"
RELEASE="15.0-RELEASE"
PG_DATA="/var/db/postgres/16/data"

echo "==> Creating jail: ${JAIL}"
if bastille list 2>/dev/null | awk '{print $2}' | grep -qx "${JAIL}"; then
    echo "    jail ${JAIL} already exists, skipping create"
else
    bastille create "${JAIL}" "${RELEASE}" "${IP}"
fi

echo "==> Starting jail: ${JAIL}"
bastille start "${JAIL}" || true

echo "==> Installing postgresql16-server"
bastille pkg "${JAIL}" install -y postgresql16-server

echo "==> Enabling postgresql service"
sysrc -j "${JAIL}" postgresql_enable=YES
sysrc -j "${JAIL}" postgresql_data="${PG_DATA}"

echo "==> Checking if initdb is needed"
if bastille cmd "${JAIL}" test -d "${PG_DATA}"; then
    echo "    ${PG_DATA} already exists, skipping initdb"
else
    echo "    Running initdb"
    bastille cmd "${JAIL}" /usr/local/etc/rc.d/postgresql initdb
fi

echo "==> Starting postgresql"
bastille service "${JAIL}" postgresql start

echo "==> Creating databases and users"
# Wait briefly for PG to accept connections
sleep 2

# craftplan database + user
bastille cmd "${JAIL}" su -m postgres -c \
    "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='craftplan'\" | grep -q 1 || \
     createuser craftplan"
bastille cmd "${JAIL}" su -m postgres -c \
    "psql -tc \"SELECT 1 FROM pg_database WHERE datname='craftplan'\" | grep -q 1 || \
     createdb -O craftplan craftplan"

# plausible database + user
bastille cmd "${JAIL}" su -m postgres -c \
    "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='plausible'\" | grep -q 1 || \
     createuser plausible"
bastille cmd "${JAIL}" su -m postgres -c \
    "psql -tc \"SELECT 1 FROM pg_database WHERE datname='plausible_db'\" | grep -q 1 || \
     createdb -O plausible plausible_db"

echo "==> Configuring pg_hba.conf for bastille0 access"
PG_HBA="${PG_DATA}/pg_hba.conf"
# Allow password auth from the bastille0 subnet
if bastille cmd "${JAIL}" grep -q "10.17.89.0/24" "${PG_HBA}" 2>/dev/null; then
    echo "    bastille0 subnet already in pg_hba.conf"
else
    bastille cmd "${JAIL}" sh -c \
        "echo 'host all all 10.17.89.0/24 scram-sha-256' >> ${PG_HBA}"
    echo "    added bastille0 subnet to pg_hba.conf"
fi

echo "==> Configuring listen_addresses"
PG_CONF="${PG_DATA}/postgresql.conf"
if bastille cmd "${JAIL}" grep -q "^listen_addresses" "${PG_CONF}" 2>/dev/null; then
    echo "    listen_addresses already set"
else
    bastille cmd "${JAIL}" sh -c \
        "echo \"listen_addresses = '0.0.0.0'\" >> ${PG_CONF}"
    echo "    set listen_addresses = '0.0.0.0'"
fi

echo "==> Setting user passwords"
# Read password from zed secrets if available, otherwise use a default
PG_PASSWD_FILE="/var/db/zed/secrets/pg_admin_passwd"
if [ -r "${PG_PASSWD_FILE}" ]; then
    PG_PASSWD="$(cat "${PG_PASSWD_FILE}")"
else
    echo "    WARNING: ${PG_PASSWD_FILE} not found, using placeholder password"
    PG_PASSWD="demo_pg_password"
fi

bastille cmd "${JAIL}" su -m postgres -c \
    "psql -c \"ALTER USER craftplan PASSWORD '${PG_PASSWD}'\""
bastille cmd "${JAIL}" su -m postgres -c \
    "psql -c \"ALTER USER plausible PASSWORD '${PG_PASSWD}'\""

echo "==> Reloading postgresql (pick up pg_hba + listen_addresses changes)"
bastille service "${JAIL}" postgresql reload

echo "==> pg jail bootstrap complete"
echo "    Jail IP:   10.17.89.20"
echo "    Databases: craftplan, plausible_db"
echo "    Users:     craftplan, plausible"
