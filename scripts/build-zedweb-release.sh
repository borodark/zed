#!/bin/sh
# scripts/build-zedweb-release.sh — build Zed's own zedweb release
# and pack it into a tarball at the Path-C7 smoke's expected location.
#
# Intended host: any FreeBSD box with Elixir + Erlang installed.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="/var/tmp/zed-smoke"
TAR_PATH="${OUT_DIR}/zedweb-0.1.0.tar.gz"

echo "==> Building mix release in ${REPO_ROOT} (target: zedweb)"
cd "${REPO_ROOT}"
mix deps.get 2>&1 | tail -3
MIX_ENV=prod mix release zedweb --overwrite 2>&1 | tail -10

REL_DIR="${REPO_ROOT}/_build/prod/rel/zedweb"

if [ ! -x "${REL_DIR}/bin/zedweb" ]; then
    echo "ERROR: expected release binary at ${REL_DIR}/bin/zedweb" >&2
    exit 1
fi

echo "==> Packing ${REL_DIR} to ${TAR_PATH}"
mkdir -p "${OUT_DIR}"
tar czf "${TAR_PATH}" -C "${REL_DIR}" .

echo "done — tarball at ${TAR_PATH}, $(du -h "${TAR_PATH}" | cut -f1)"
