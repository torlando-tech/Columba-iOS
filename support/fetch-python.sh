#!/usr/bin/env bash
# Fetch BeeWare's Python-Apple-support iOS distribution into Frameworks/.
# Produces Frameworks/Python.xcframework + Frameworks/VERSIONS.
#
# Idempotent: re-running is cheap; only re-downloads when the pinned version
# differs from what's already on disk.
#
# Pinned to a specific release for reproducibility. Bump intentionally.

set -euo pipefail

# ----- Pinned versions -----
PY_VERSION="3.13"
PY_BUILD="b13"                          # bump when a newer iOS support release is needed
RELEASE_TAG="${PY_VERSION}-${PY_BUILD}"
TARBALL="Python-${PY_VERSION}-iOS-support.${PY_BUILD}.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/${RELEASE_TAG}/${TARBALL}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW_DIR="$ROOT/Frameworks"
DOWNLOAD_PATH="$FW_DIR/${TARBALL}.part"
STAGE_DIR="$FW_DIR/.python-stage.$$"
mkdir -p "$FW_DIR"

cleanup() {
    rm -f "$DOWNLOAD_PATH"
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# Bail early if the right version is already installed.
if [ -f "$FW_DIR/VERSIONS" ] && grep -q "Build: ${PY_BUILD}" "$FW_DIR/VERSIONS"; then
    echo "Python.xcframework already at $RELEASE_TAG; nothing to fetch."
    exit 0
fi

# Xcode Cloud occasionally resets long GitHub release-asset connections. Retry
# every curl-class failure, including exit 35 (TLS/connection reset), while
# bounding both connection setup and the total retry window.
rm -f "$DOWNLOAD_PATH"
echo "==> Fetching $TARBALL"
curl --fail --location --progress-bar \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    --retry-max-time 600 \
    --connect-timeout 30 \
    --output "$DOWNLOAD_PATH" \
    "$URL"

# Validate and fully extract into staging before touching an existing runtime.
# A truncated 2xx response must not destroy a previously valid framework.
echo "==> Validating archive"
tar -tzf "$DOWNLOAD_PATH" >/dev/null

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
echo "==> Extracting"
tar -xzf "$DOWNLOAD_PATH" -C "$STAGE_DIR"

if [ ! -d "$STAGE_DIR/Python.xcframework" ] || [ ! -f "$STAGE_DIR/VERSIONS" ]; then
    echo "error: downloaded archive is missing Python.xcframework or VERSIONS" >&2
    exit 1
fi

echo "==> Replacing stale Python.xcframework (if any)"
rm -rf "$FW_DIR/Python.xcframework" "$FW_DIR/testbed" "$FW_DIR/VERSIONS"
mv "$STAGE_DIR/Python.xcframework" "$FW_DIR/Python.xcframework"
mv "$STAGE_DIR/VERSIONS" "$FW_DIR/VERSIONS"

# The testbed/ directory is a BeeWare reference Xcode project — we don't need it.
rm -rf "$STAGE_DIR/testbed"

echo "==> Done. Python.xcframework installed:"
cat "$FW_DIR/VERSIONS"
