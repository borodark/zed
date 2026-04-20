#!/bin/sh
# demo-bootstrap.sh — initialise a zed test deployment.
#
# Creates <ZED_DEMO_BASE>/zed + /secrets under the delegated subtree
# `jeff/zed-test/manual` by default. Generates all slots in the
# catalog. Idempotent — safe to re-run (already-stamped slots are
# skipped; no new snapshot).
#
# Override via env:
#   ZED_DEMO_BASE          parent dataset for zed      (default jeff/zed-test/manual)
#   ZED_DEMO_MOUNT         mountpoint for /secrets     (default /tmp/zed-manual-test)
#   ZED_BOOTSTRAP_PASSPHRASE dataset encryption key    (default test-demomix)
#   ZED_DEMO_ADMIN_PASSWD  admin web UI password       (default demoadmin)
#
# Tear down:
#   zfs destroy -rf <ZED_DEMO_BASE>
#   rm -rf <ZED_DEMO_MOUNT>

set -eu

BASE=${ZED_DEMO_BASE:-jeff/zed-test/manual}
MOUNT=${ZED_DEMO_MOUNT:-/tmp/zed-manual-test}
PASS=${ZED_BOOTSTRAP_PASSPHRASE:-test-demomix}
ADMIN=${ZED_DEMO_ADMIN_PASSWD:-demoadmin}

export ZED_BOOTSTRAP_PASSPHRASE=$PASS

echo "BASE=$BASE"
echo "MOUNT=$MOUNT"
echo "ADMIN=$ADMIN"
echo

exec mix run --no-halt -e "Zed.CLI.main([
  \"bootstrap\",
  \"init\",
  \"--base\", \"$BASE\",
  \"--mountpoint\", \"$MOUNT\",
  \"--admin-passwd\", \"$ADMIN\"
])"
