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

# Xcode's bundled Python can ship a pip too old for PEP 621 metadata. Use an
# isolated, pinned packaging toolchain so ble-reticulum cannot silently become
# an empty UNKNOWN-0.0.0 distribution.
PIP_VENV="$(mktemp -d "${TMPDIR:-/tmp}/columba-wheel-pip.XXXXXX")"
trap 'rm -rf "$PIP_VENV"' EXIT
python3 -m venv "$PIP_VENV"
PIP_PYTHON="$PIP_VENV/bin/python"
"$PIP_PYTHON" -m pip install --quiet --upgrade \
    "pip==25.1.1" "setuptools==80.9.0" "wheel==0.45.1"

# Pure-Python pinned versions — empty means latest. Pin in production.
# (msgpack intentionally NOT installed: RNS and LXMF use the vendored pure-Python
#  umsgpack in RNS.vendor.umsgpack. Installing the binary msgpack wheel from PyPI
#  pulls a macOS-built .so that won't load on iOS.)
#
# RNS is sourced from an immutable Torlando fork commit (not PyPI or a moving
# branch) so every build resolves the same reviewed dependency payload.
# To develop the fork itself, point at a local working copy explicitly:
#   RETICULUM_LOCAL=~/repos/Reticulum support/fetch-wheels.sh
# Otherwise the pinned GitHub commit is used — a local checkout is never picked
# up implicitly.
RETICULUM_REF="${RETICULUM_REF:-1c2cf73443ce73613bd67ea8412e7923d34cd7e6}"
if [ -n "${RETICULUM_LOCAL:-}" ]; then
    echo "==> RETICULUM_LOCAL set — using local Reticulum checkout: $RETICULUM_LOCAL"
    RNS_SPEC="$RETICULUM_LOCAL"
else
    RNS_SPEC="git+https://github.com/torlando-tech/Reticulum.git@${RETICULUM_REF}"
fi
# LXMF is likewise pinned to the cooperative external-stamp producer commit.
# Point at a local working copy only when explicitly developing the fork:
#   LXMF_LOCAL=~/repos/LXMF support/fetch-wheels.sh
LXMF_REF="${LXMF_REF:-fbcb8f83109b93d2491632427716c7fcd645c605}"
if [ -n "${LXMF_LOCAL:-}" ]; then
    echo "==> LXMF_LOCAL set — using local LXMF checkout: $LXMF_LOCAL"
    LXMF_SPEC="$LXMF_LOCAL"
else
    LXMF_SPEC="git+https://github.com/torlando-tech/LXMF.git@${LXMF_REF}"
fi
PYSERIAL_SPEC="pyserial>=3.5"
# ble-reticulum is not on PyPI; install from GitHub unless an explicit local
# checkout is requested via env-var (mirrors LXMF_LOCAL / RETICULUM_LOCAL). A
# local checkout is NEVER picked up implicitly — that made builds depend on
# whatever branch happened to be checked out on the dev's machine.
#   BLE_RETICULUM_LOCAL=~/repos/ble-reticulum support/fetch-wheels.sh
# Pure-Python, zero runtime deps.
# Pinned to a commit (not a bare repo URL or a moving branch) so CI and dev
# builds are reproducible — bump deliberately. The local checkout is 49 commits
# past the v0.2.2 tag, so a tag pin would regress; this is origin/main@07d9413.
BLE_RETICULUM_REF="${BLE_RETICULUM_REF:-07d941304c9a1dc3a8e58087b3b974ff3d229e56}"
if [ -n "${BLE_RETICULUM_LOCAL:-}" ]; then
    echo "==> BLE_RETICULUM_LOCAL set — using local ble-reticulum checkout: $BLE_RETICULUM_LOCAL"
    BLE_RETICULUM_SPEC="$BLE_RETICULUM_LOCAL"
else
    BLE_RETICULUM_SPEC="git+https://github.com/torlando-tech/ble-reticulum.git@${BLE_RETICULUM_REF}"
fi

rm -rf "$SIM_DIR" "$DEV_DIR"
mkdir -p "$SIM_DIR" "$DEV_DIR"
PURE_DIR="$PIP_VENV/pure-python"
mkdir -p "$PURE_DIR"

install_binary_wheel() {
    # $1 platform tag, $2 destination dir, $3+ pkg specs
    local platform=$1 dst=$2; shift 2
    echo "==> Fetching binary wheels for $platform: $@"
    "$PIP_PYTHON" -m pip install \
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
    "$PIP_PYTHON" -m pip install \
        --no-deps \
        --target "$dst" \
        --upgrade \
        "$@"
}

validate_pure_python() {
    local dst=$1 metadata_count metadata
    for payload in \
        RNS/__init__.py \
        LXMF/__init__.py \
        serial/__init__.py \
        ble_reticulum/BLEInterface.py; do
        [ -s "$dst/$payload" ] || {
            echo "error: pure-Python payload missing from $dst: $payload" >&2
            exit 1
        }
    done
    # Keep the shipping BLE entry point explicit: an empty/mispackaged VCS
    # wheel must fail before either platform payload is published.
    [ -s "$dst/ble_reticulum/BLEInterface.py" ] || {
        echo "error: ble-reticulum package payload missing from $dst" >&2
        exit 1
    }

    # Require named and versioned metadata for all four packages. This catches
    # stale host build tooling producing an empty UNKNOWN-0.0.0 distribution.
    metadata_count=0
    for metadata in "$dst"/*.dist-info/METADATA; do
        [ -s "$metadata" ] || continue
        grep -q '^Name: .\+' "$metadata" || continue
        grep -q '^Version: .\+' "$metadata" || continue
        metadata_count=$((metadata_count + 1))
    done
    [ "$metadata_count" -ge 4 ] || {
        echo "error: expected version metadata for four pure-Python packages in $dst" >&2
        exit 1
    }
}

copy_pure_python() {
    local src=$1 dst=$2
    cp -R "$src/." "$dst/"
    validate_pure_python "$dst"
}

# cffi is needed because cryptography $CRYPTO_VERSION still depends on cffi for
# parts of its OpenSSL bindings. Pin cffi 2.0.0 (matching cp313 wheel
# availability on BeeWare).
BINARY_WHEELS=(
    "cryptography==$CRYPTO_VERSION"
    "cffi==2.0.0"
)
install_binary_wheel "$PLATFORM_SIM" "$SIM_DIR" "${BINARY_WHEELS[@]}"
install_binary_wheel "$PLATFORM_DEV" "$DEV_DIR" "${BINARY_WHEELS[@]}"

install_pure_python "$PURE_DIR" "$RNS_SPEC" "$LXMF_SPEC" "$PYSERIAL_SPEC" "$BLE_RETICULUM_SPEC"
validate_pure_python "$PURE_DIR"
copy_pure_python "$PURE_DIR" "$SIM_DIR"
copy_pure_python "$PURE_DIR" "$DEV_DIR"

echo
echo "Wheels installed:"
du -sh "$SIM_DIR" "$DEV_DIR"
