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
RETICULUM_REF="${RETICULUM_REF:-5b3a6ee4f25e2925cf84d4a2b108e6a708fbd395}"
if [ -n "${RETICULUM_LOCAL:-}" ]; then
    echo "==> RETICULUM_LOCAL set — using local Reticulum checkout: $RETICULUM_LOCAL"
    RNS_SPEC="$RETICULUM_LOCAL"
else
    RNS_SPEC="git+https://github.com/torlando-tech/Reticulum.git@${RETICULUM_REF}"
fi
# LXMF is likewise pinned to the cooperative external-stamp producer commit.
# Point at a local working copy only when explicitly developing the fork:
#   LXMF_LOCAL=~/repos/LXMF support/fetch-wheels.sh
LXMF_REF="${LXMF_REF:-8912186e48b482a76bf04e2ac4b6c8940991aecc}"
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
    local dst=$1
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

    # Validate the exact distributions and immutable VCS revisions, not merely
    # the number of metadata directories produced by pip.
    "$PIP_PYTHON" - "$dst" \
        "${RETICULUM_LOCAL:+LOCAL}${RETICULUM_LOCAL:-$RETICULUM_REF}" \
        "${LXMF_LOCAL:+LOCAL}${LXMF_LOCAL:-$LXMF_REF}" \
        "${BLE_RETICULUM_LOCAL:+LOCAL}${BLE_RETICULUM_LOCAL:-$BLE_RETICULUM_REF}" <<'PY'
import email.parser
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
expected_refs = dict(zip(("rns", "lxmf", "ble-reticulum"), sys.argv[2:]))
expected_names = {"rns", "lxmf", "pyserial", "ble-reticulum"}
found = {}


def normalized(value):
    return re.sub(r"[-_.]+", "-", value.strip().lower())


for metadata_path in root.glob("*.dist-info/METADATA"):
    metadata = email.parser.Parser().parsestr(metadata_path.read_text(encoding="utf-8"))
    name = normalized(metadata.get("Name", ""))
    version = metadata.get("Version", "").strip().lower()
    if name in expected_names:
        if not version or version in {"unknown", "0.0.0"}:
            raise SystemExit(f"error: invalid {name} package version: {version!r}")
        if name in found:
            raise SystemExit(f"error: duplicate package metadata for {name}")
        found[name] = metadata_path.parent

missing = expected_names - found.keys()
if missing:
    raise SystemExit(f"error: missing package metadata for: {', '.join(sorted(missing))}")

for name, expected_ref in expected_refs.items():
    if expected_ref.startswith("LOCAL"):
        continue
    direct_url_path = found[name] / "direct_url.json"
    try:
        direct_url = json.loads(direct_url_path.read_text(encoding="utf-8"))
        commit_id = direct_url["vcs_info"]["commit_id"]
    except (OSError, KeyError, TypeError, ValueError) as error:
        raise SystemExit(f"error: invalid VCS metadata for {name}: {error}")
    if commit_id != expected_ref:
        raise SystemExit(
            f"error: {name} VCS revision {commit_id!r} does not match {expected_ref!r}"
        )
PY
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
