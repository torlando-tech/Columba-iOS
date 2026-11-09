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
CFFI_VERSION="2.0.0"
PYTHON_TAG="cp313"
PLATFORM_SIM="ios_13_0_arm64_iphonesimulator"
PLATFORM_DEV="ios_13_0_arm64_iphoneos"

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
#
# RNS 1.6.0 plus native hash search, AutoInterface lifecycle fixes and reduced receive copies.
RETICULUM_REF="${RETICULUM_REF:-0816be02b5f43b643b980e8262c7c7f2a4fc3d56}"
if [ -n "${RETICULUM_LOCAL:-}" ]; then
    echo "==> RETICULUM_LOCAL set — using local Reticulum checkout: $RETICULUM_LOCAL"
    RNS_SPEC="$RETICULUM_LOCAL"
else
    RNS_SPEC="git+https://github.com/torlando-tech/Reticulum.git@${RETICULUM_REF}"
fi
# LXMF 1.3.0 plus receiving metadata and mutex-serialized SQLite compatibility.
# Point at a local working copy only when explicitly developing the fork:
#   LXMF_LOCAL=~/repos/LXMF support/fetch-wheels.sh
LXMF_REF="${LXMF_REF:-09cd6be4324345ed07964e9f6e5372308f6d6883}"
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
# builds are reproducible — bump deliberately. This is the v0.2.3 tag
# (origin/main@63557ac). v0.2.3 is code-identical to ed164a8 except the
# pyproject version (0.2.2 -> 0.2.3) + CHANGELOG, so the Swift<->Python C-ABI
# is unchanged by this bump.
BLE_RETICULUM_REF="${BLE_RETICULUM_REF:-63557acfe5c923dcdafeb7bc37508bf835f16514}"
if [ -n "${BLE_RETICULUM_LOCAL:-}" ]; then
    echo "==> BLE_RETICULUM_LOCAL set — using local ble-reticulum checkout: $BLE_RETICULUM_LOCAL"
    BLE_RETICULUM_SPEC="$BLE_RETICULUM_LOCAL"
else
    BLE_RETICULUM_SPEC="git+https://github.com/torlando-tech/ble-reticulum.git@${BLE_RETICULUM_REF}"
fi


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

validate_wheels() {
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
        "${BLE_RETICULUM_LOCAL:+LOCAL}${BLE_RETICULUM_LOCAL:-$BLE_RETICULUM_REF}" \
        "${2:-}" "$PYTHON_TAG" "$CRYPTO_VERSION" "$CFFI_VERSION" <<'PY'
import email.parser
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
expected_refs = dict(zip(("rns", "lxmf", "ble-reticulum"), sys.argv[2:]))
platform_tag, python_tag, crypto_version, cffi_version = sys.argv[5:]
binary_versions = {"cryptography": crypto_version, "cffi": cffi_version} if platform_tag else {}
expected_names = {"rns", "lxmf", "pyserial", "ble-reticulum"} | binary_versions.keys()
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
        if name in binary_versions and version != binary_versions[name]:
            raise SystemExit(f"error: {name} version {version!r} does not match {binary_versions[name]!r}")
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

for name, pattern in (("cryptography", "cryptography/**/*.so"), ("cffi", "_cffi_backend*.so")):
    if name not in binary_versions:
        continue
    wheel = email.parser.Parser().parsestr((found[name] / "WHEEL").read_text(encoding="utf-8"))
    if not any(tag.startswith(python_tag + "-") and tag.endswith("-" + platform_tag)
               for tag in wheel.get_all("Tag", [])):
        raise SystemExit(f"error: {name} wheel does not match {python_tag}/{platform_tag}")
    if not any(path.is_file() and path.stat().st_size > 0 for path in root.glob(pattern)):
        raise SystemExit(f"error: missing native module for {name}")
PY
}

PIP_PYTHON=python3
if [ -z "${RETICULUM_LOCAL:-}${LXMF_LOCAL:-}${BLE_RETICULUM_LOCAL:-}" ] &&
   (validate_wheels "$SIM_DIR" "$PLATFORM_SIM" &&
    validate_wheels "$DEV_DIR" "$PLATFORM_DEV") >/dev/null 2>&1; then
    echo "Python wheels match pinned revisions and platforms, reusing."
    exit 0
fi

source "$POC_ROOT/support/bootstrap-pip.sh"
rm -rf "$SIM_DIR" "$DEV_DIR"
mkdir -p "$SIM_DIR" "$DEV_DIR"
PURE_DIR="$PIP_VENV/pure-python"
mkdir -p "$PURE_DIR"

copy_pure_python() {
    local src=$1 dst=$2
    cp -R "$src/." "$dst/"
    validate_wheels "$dst" "$3"
}

# cffi is needed because cryptography $CRYPTO_VERSION still depends on cffi for
# parts of its OpenSSL bindings. Pin cffi 2.0.0 (matching cp313 wheel
# availability on BeeWare).
BINARY_WHEELS=(
    "cryptography==$CRYPTO_VERSION"
    "cffi==$CFFI_VERSION"
)
install_binary_wheel "$PLATFORM_SIM" "$SIM_DIR" "${BINARY_WHEELS[@]}"
install_binary_wheel "$PLATFORM_DEV" "$DEV_DIR" "${BINARY_WHEELS[@]}"

install_pure_python "$PURE_DIR" "$RNS_SPEC" "$LXMF_SPEC" "$PYSERIAL_SPEC" "$BLE_RETICULUM_SPEC"
validate_wheels "$PURE_DIR"
copy_pure_python "$PURE_DIR" "$SIM_DIR" "$PLATFORM_SIM"
copy_pure_python "$PURE_DIR" "$DEV_DIR" "$PLATFORM_DEV"

echo
echo "Wheels installed:"
du -sh "$SIM_DIR" "$DEV_DIR"
