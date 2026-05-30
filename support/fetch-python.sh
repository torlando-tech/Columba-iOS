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
mkdir -p "$FW_DIR"

# Bail early if the right version is already installed.
if [ -f "$FW_DIR/VERSIONS" ] && grep -q "Build: ${PY_BUILD}" "$FW_DIR/VERSIONS"; then
    echo "Python.xcframework already at $RELEASE_TAG; nothing to fetch."
    exit 0
fi

echo "==> Fetching $TARBALL"
curl -fL --progress-bar -o "$FW_DIR/$TARBALL" "$URL"

echo "==> Removing stale Python.xcframework (if any)"
rm -rf "$FW_DIR/Python.xcframework" "$FW_DIR/testbed" "$FW_DIR/VERSIONS"

echo "==> Extracting"
tar -xzf "$FW_DIR/$TARBALL" -C "$FW_DIR"
rm "$FW_DIR/$TARBALL"
# The testbed/ directory is a BeeWare reference Xcode project — we don't need it
# in this repo. Saves ~5 MB on a fresh checkout.
rm -rf "$FW_DIR/testbed"

echo "==> Done. Python.xcframework installed:"
cat "$FW_DIR/VERSIONS"
