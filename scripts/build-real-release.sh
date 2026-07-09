#!/bin/sh
# scripts/build-real-release.sh — build hello_beam's mix release and
# pack it into a tarball at the Path-C3 smoke's expected location.
#
# Intended host: any FreeBSD box with Elixir + Erlang installed. On
# mac-248 the system Erlang/OTP 26 + Elixir 1.17.3 (via pkg) work.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${REPO_ROOT}/hello_beam"
OUT_DIR="/var/tmp/zed-smoke"
TAR_PATH="${OUT_DIR}/hello_beam-0.1.0.tar.gz"

echo "==> Building mix release in ${APP_DIR}"
cd "${APP_DIR}"
mix deps.get 2>&1 | tail -3
MIX_ENV=prod mix release --overwrite 2>&1 | tail -10

REL_DIR="${APP_DIR}/_build/prod/rel/hello_beam"

if [ ! -x "${REL_DIR}/bin/hello_beam" ]; then
    echo "ERROR: expected release binary at ${REL_DIR}/bin/hello_beam" >&2
    exit 1
fi

echo "==> Packing ${REL_DIR} to ${TAR_PATH}"
mkdir -p "${OUT_DIR}"
tar czf "${TAR_PATH}" -C "${REL_DIR}" .

echo "done — tarball at ${TAR_PATH}, $(du -h "${TAR_PATH}" | cut -f1)"
