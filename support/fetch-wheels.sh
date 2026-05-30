#!/usr/bin/env bash
# Fetch and unpack Python wheels for iOS into per-platform directories.
#
# Output:
#   wheels-iphonesimulator/   simulator wheels (cryptography iOS-sim build + common pure-Python)
#   wheels-iphoneos/          device wheels (cryptography iOS-device build + common pure-Python)
#
# Pure-Python wheels are duplicated into both dirs so the build-phase copy is platform-agnostic.
#
# Requires:
#   * python3 with pip on the host
#   * Internet (BeeWare anaconda + PyPI)

set -euo pipefail

POC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_DIR="$POC_ROOT/wheels-iphonesimulator"
DEV_DIR="$POC_ROOT/wheels-iphoneos"

BEEWARE_INDEX="https://pypi.anaconda.org/beeware/simple"
CRYPTO_VERSION="47.0.0"
PYTHON_TAG="cp313"
PLATFORM_SIM="ios_13_0_arm64_iphonesimulator"
PLATFORM_DEV="ios_13_0_arm64_iphoneos"

# Pure-Python pinned versions — empty means latest. Pin in production.
# (msgpack intentionally NOT installed: RNS and LXMF use the vendored pure-Python
#  umsgpack in RNS.vendor.umsgpack. Installing the binary msgpack wheel from PyPI
#  pulls a macOS-built .so that won't load on iOS.)
#
# RNS is sourced permanently from Torlando's fork branch (not PyPI, not a local
# checkout) so every build — CI and local — resolves the same dependency. The
# patches/columba-ios branch carries iOS-specific patches (e.g. the
# AutoInterface.detach() teardown that lets Columba hot-add / hot-remove
# interfaces on a running stack).
#
# To develop the fork itself, point at a local working copy explicitly:
#   RETICULUM_LOCAL=~/repos/Reticulum support/fetch-wheels.sh
# Otherwise the GitHub branch is always used — the local checkout is never
# picked up implicitly (that made builds depend on whatever branch happened to
# be checked out on the dev's machine).
RETICULUM_BRANCH="patches/columba-ios"
if [ -n "${RETICULUM_LOCAL:-}" ]; then
    echo "==> RETICULUM_LOCAL set — using local Reticulum checkout: $RETICULUM_LOCAL"
    RNS_SPEC="$RETICULUM_LOCAL"
else
    RNS_SPEC="git+https://github.com/torlando-tech/Reticulum.git@${RETICULUM_BRANCH}"
fi
# LXMF: torlando-tech fork with the external stamp generator hook. iOS embedded
# CPython has no `_multiprocessing`, so stock LXStamper's job_linux crashes and
# no stamp is produced (messages to stamp-cost peers like Sideband never
# deliver). The fork's `set_external_generator` lets us run the PoW in native
# Swift (see app/rns_bridge.py + Sources/SwiftBLEBridge/StampGenerator.swift).
# Branch is 0.9.9 + the hook (forward-port of feature/external-stamp-generator).
# Point at a local working copy to develop the fork:
#   LXMF_LOCAL=~/repos/LXMF support/fetch-wheels.sh   (branch feature/external-stamp-generator-0.9.9)
LXMF_BRANCH="feature/external-stamp-generator-0.9.9"
if [ -n "${LXMF_LOCAL:-}" ]; then
    echo "==> LXMF_LOCAL set — using local LXMF checkout: $LXMF_LOCAL"
    LXMF_SPEC="$LXMF_LOCAL"
else
    LXMF_SPEC="git+https://github.com/torlando-tech/LXMF.git@${LXMF_BRANCH}"
fi
PYSERIAL_SPEC="pyserial>=3.5"
# ble-reticulum is not on PyPI; install from the local checkout if present,
# otherwise from Torlando's GitHub. Pure-Python, zero runtime deps.
BLE_RETICULUM_LOCAL="$HOME/repos/ble-reticulum"
if [ -d "$BLE_RETICULUM_LOCAL" ]; then
    BLE_RETICULUM_SPEC="$BLE_RETICULUM_LOCAL"
else
    BLE_RETICULUM_SPEC="git+https://github.com/torlando-tech/ble-reticulum.git"
fi

rm -rf "$SIM_DIR" "$DEV_DIR"
mkdir -p "$SIM_DIR" "$DEV_DIR"

install_binary_wheel() {
    # $1 platform tag, $2 destination dir, $3+ pkg specs
    local platform=$1 dst=$2; shift 2
    echo "==> Fetching binary wheels for $platform: $@"
    python3 -m pip install \
        --index-url "$BEEWARE_INDEX" \
        --platform "$platform" \
        --python-version 3.13 \
        --implementation cp \
        --only-binary :all: \
        --no-deps \
        --target "$dst" \
        --upgrade \
        "$@"
}

install_pure_python() {
    # $1 destination dir, $2+ specs
    local dst=$1; shift
    echo "==> Fetching pure-Python wheels into $dst"
    python3 -m pip install \
        --no-deps \
        --target "$dst" \
        --upgrade \
        "$@"
}

# cffi is needed because cryptography 47.0.0.dev1 still uses cffi for some bindings.
# pin to cffi 2.0.0 (matching cp313 wheel availability on BeeWare).
BINARY_WHEELS=(
    "cryptography==$CRYPTO_VERSION"
    "cffi==2.0.0"
)
install_binary_wheel "$PLATFORM_SIM" "$SIM_DIR" "${BINARY_WHEELS[@]}"
install_binary_wheel "$PLATFORM_DEV" "$DEV_DIR" "${BINARY_WHEELS[@]}"

for dst in "$SIM_DIR" "$DEV_DIR"; do
    install_pure_python "$dst" "$RNS_SPEC" "$LXMF_SPEC" "$PYSERIAL_SPEC" "$BLE_RETICULUM_SPEC"
done

echo
echo "Wheels installed:"
du -sh "$SIM_DIR" "$DEV_DIR"
