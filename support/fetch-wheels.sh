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

# The interpreter's ensurepip pip can be too old for the interpreter ITSELF
# (Python 3.15 removed typing.no_type_check_decorator, which pip <= 25.1.x
# vendored typing_extensions imports at startup - pip crashes before it can
# upgrade itself) or too old for PEP 621 metadata. Create the venv WITHOUT
# pip and bootstrap pip explicitly, then install the pinned packaging
# toolchain with it so ble-reticulum cannot silently become an empty
# UNKNOWN-0.0.0 distribution.
#
# The bootstrap source depends on the HOST interpreter, because macOS system
# python3 is 3.9.6 (Xcode Cloud runners included) and the rolling
# bootstrap.pypa.io/pip/pip.pyz tracks the LATEST pip, which requires
# >= 3.10 - running it under 3.9 aborts with "This version of pip does not
# support python 3.9" and fails every fresh-clone build (post-clone hook).
# So: >= 3.10 hosts get the rolling zipapp + the pip==26.2.1 pin (3.15
# capable, proven on the runner); older hosts get pypa's per-version
# get-pip channel, which serves the last pip that supports that interpreter
# (25.x on 3.9 - new enough for PEP 621 metadata and the cross-platform
# --target installs below).
PIP_VENV="$(mktemp -d "${TMPDIR:-/tmp}/columba-wheel-pip.XXXXXX")"
trap 'rm -rf "$PIP_VENV"' EXIT
python3 -m venv --without-pip "$PIP_VENV"
PIP_PYTHON="$PIP_VENV/bin/python"
# Xcode Cloud intermittently resets long downloads; --fail keeps an HTTP
# error page from being saved as the bootstrap file (Python would then "run"
# the error page), and the bounded retries match fetch-python.sh's convention.
CURL=(curl --fail --silent --show-error --location
      --retry 5 --retry-all-errors --retry-delay 2
      --retry-max-time 600 --connect-timeout 30)
if "$PIP_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    "${CURL[@]}" --output "$PIP_VENV/pip.pyz" https://bootstrap.pypa.io/pip/pip.pyz
    "$PIP_PYTHON" "$PIP_VENV/pip.pyz" install --quiet \
        "pip==26.2.1" "setuptools==80.9.0" "wheel==0.45.1"
else
    HOST_SERIES="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    echo "==> Host python3 is $HOST_SERIES (< 3.10): bootstrapping pip from the $HOST_SERIES get-pip channel"
    "${CURL[@]}" --output "$PIP_VENV/get-pip.py" \
        "https://bootstrap.pypa.io/pip/${HOST_SERIES}/get-pip.py"
    "$PIP_PYTHON" "$PIP_VENV/get-pip.py" --quiet \
        "setuptools==80.9.0" "wheel==0.45.1"
fi
# Functional floor, not an exact pin: pip must be >= 25 (PEP 621 metadata +
# the cross-platform flags used below) and actually runnable.
"$PIP_PYTHON" -m pip --version | grep -qE "pip (2[5-9]|[3-9][0-9])\."

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
# Pinned to the branch `rebase/columba-1.5.5` (head 3759488e): RNS 1.5.5 plus the
# SAME six columba embedded-runtime hardening commits the previous pin
# (754654fe, RNS 1.5.2 + 6) carried, re-applied on top of 1.5.5. 1.5.5 adds live
# interface attach/detach/reload (RNS.Reticulum.attach_interface /
# detach_interface / reload_interface) and a real AutoInterface.detach() teardown
# — the teardown the in-NE node relies on for hot interface swaps. Bump
# deliberately; the commit is on the same remote this script pulls from.
RETICULUM_REF="${RETICULUM_REF:-3759488eba880489562268d9a1a993f443d1b8bd}"
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
