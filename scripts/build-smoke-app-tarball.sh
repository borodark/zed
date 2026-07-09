#!/bin/sh
# scripts/build-smoke-app-tarball.sh — stage a minimal fake-release
# tarball for the Path C1 smoke (Zed.Examples.SmokeContainedApp).
#
# The tarball layout mimics a mix release enough that the rc.d
# script's `command="<mount>/current/bin/hello daemon"` invocation
# finds an executable. The command itself is a shell stub that
# backgrounds a `sleep` process and writes a pidfile — enough for
# FreeBSD's rc.subr to report status:running. NOT a real BEAM
# release; that comes with the DemoOffCompose smoke.
#
# Idempotent — overwrites the tarball on each run.

set -eu

STAGING="/tmp/zed-smoke-hello-build"
OUT_DIR="/var/tmp/zed-smoke"
TAR_PATH="${OUT_DIR}/hello-0.1.0.tar.gz"
APP="hello"

echo "==> Preparing staging: ${STAGING}"
rm -rf "${STAGING}"
mkdir -p "${STAGING}/bin"

echo "==> Writing bin/${APP} shell stub"
cat > "${STAGING}/bin/${APP}" <<'SHELL_STUB'
#!/bin/sh
# Fake mix-release runner — supports the subcommands FreeBSD rc(8)
# will pass through: daemon (background + pidfile), stop, status.

APP="hello"
PIDFILE="/var/run/${APP}.pid"

case "${1:-}" in
  daemon)
    # Background a long-running sleep so rc.subr's pidfile check
    # reports :running. Real releases delegate to BEAM's daemon runner.
    (while :; do sleep 60; done) &
    echo $! > "${PIDFILE}"
    ;;
  stop)
    if [ -f "${PIDFILE}" ]; then
      kill "$(cat "${PIDFILE}")" 2>/dev/null || true
      rm -f "${PIDFILE}"
    fi
    ;;
  status)
    if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
      exit 0
    else
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 {daemon|stop|status}" >&2
    exit 64
    ;;
esac
SHELL_STUB

chmod +x "${STAGING}/bin/${APP}"

echo "==> Packing tarball to ${TAR_PATH}"
mkdir -p "${OUT_DIR}"
tar czf "${TAR_PATH}" -C "${STAGING}" .

echo "==> Cleaning staging"
rm -rf "${STAGING}"

echo "done — tarball at ${TAR_PATH}, $(du -h "${TAR_PATH}" | cut -f1)"
