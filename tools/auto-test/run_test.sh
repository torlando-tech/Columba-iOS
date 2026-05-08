#!/usr/bin/env bash
# Drive an end-to-end check of the Columba extension's AutoInterface.
#
# Prereqs (run once):
#   - Mac on the same Wi-Fi as the iPhone
#   - iPhone paired via `xcrun devicectl` (Wi-Fi pairing OK)
#   - VPN profile installed and Background Transport ON in Columba
#   - $DEVICE_UDID set or passed via `--device`
#
# What this does (each iteration):
#   1. Build + install the latest Columba.app
#   2. Relaunch the app (`devicectl process launch --terminate-existing`)
#      — this will trigger auto-restart of the tunnel via the saved
#      pref. Note: iOS keeps the running extension instance across
#      app reinstalls, so the new extension binary may not load
#      until the user manually deletes/re-adds the VPN profile or
#      we add a programmatic force-reload (see TODO in this script).
#   3. Wait for the tunnel to settle.
#   4. Send AutoInterface-shaped test traffic from this Mac:
#      - 3 multicast HELLO beacons to ff12:0:… port 29716
#      - 1 unicast announce-shaped UDP packet to iPhone:42671
#   5. Wait briefly for the extension to log + queue any received
#      packets.
#   6. Pull `Library/Caches/ext_diag.log` from the App Group container.
#   7. Pull `Documents/diag.log` from the app container.
#   8. Verify the expected log entries are present.
#
# Exit code is 0 if all expected entries are present, non-zero
# otherwise — usable in CI / a watch loop.
#
# TODO (not blocking): bake a "/debug/reload-extension" handleAppMessage
# command into the extension that calls `cancelTunnelWithError`, so
# this script can force the new binary to load without the user
# tapping anything in iOS Settings.

set -euo pipefail

DEVICE_UDID="${DEVICE_UDID:-330CDDB1-B2C2-5AE0-B3FC-2442F7E1AF60}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-M2977H5PM5}"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_BUNDLE_ID="network.columba.Columba"
APP_GROUP_ID="group.network.columba.Columba"
# Resolve `DERIVED` from xcodebuild's BUILD_DIR rather than baking in
# a DerivedData hash — Xcode regenerates that hash on rename / clone /
# fresh checkout, so the literal path was breaking even on Tyler's
# machine after a re-clone, and never worked for any other contributor.
# Override DERIVED via env to skip this query (e.g. when --skip-build
# is used).
if [[ -z "${DERIVED:-}" ]]; then
    DERIVED_BUILD_DIR=$(cd "$PROJECT_DIR" && xcodebuild \
        -project Columba.xcodeproj -scheme Columba \
        -configuration Debug -sdk iphoneos \
        -showBuildSettings 2>/dev/null \
        | awk '/^[[:space:]]*BUILD_DIR = /{print $3; exit}')
    if [[ -z "$DERIVED_BUILD_DIR" ]]; then
        echo "ERROR: could not resolve BUILD_DIR from xcodebuild — set \$DERIVED manually." >&2
        exit 1
    fi
    DERIVED="$DERIVED_BUILD_DIR/Debug-iphoneos/ColumbaApp.app"
fi

usage() {
    cat <<EOF
Usage: $0 [--device UDID] [--target-ip IPV6]

  --device UDID       iPhone UDID (default: \$DEVICE_UDID)
  --target-ip IPV6    iPhone link-local IPv6 (without %scope)
  --skip-build        Skip xcodebuild + install (use existing build)
  --skip-traffic      Skip test traffic (just pull and verify logs)
  --help              Show this help

Set TARGET_IP via env or --target-ip (e.g. fe80::14cb:9def:5400:73b9).
EOF
}

TARGET_IP="${TARGET_IP:-}"
SKIP_BUILD=0
SKIP_TRAFFIC=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE_UDID="$2"; shift 2;;
        --target-ip) TARGET_IP="$2"; shift 2;;
        --skip-build) SKIP_BUILD=1; shift;;
        --skip-traffic) SKIP_TRAFFIC=1; shift;;
        --help) usage; exit 0;;
        *) echo "unknown arg: $1"; usage; exit 1;;
    esac
done

if [[ -z "$TARGET_IP" ]]; then
    echo "ERROR: target IP not set. Use --target-ip or \$TARGET_IP."
    exit 1
fi

cd "$PROJECT_DIR"

if [[ "$SKIP_BUILD" == "0" ]]; then
    echo "[1/8] Building..."
    xcodebuild build -project Columba.xcodeproj -scheme Columba \
        -configuration Debug -sdk iphoneos \
        -destination "id=$DEVICE_UDID" \
        CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" \
        -allowProvisioningUpdates 2>&1 | tail -3

    echo "[2/8] Installing..."
    xcrun devicectl device install app --device "$DEVICE_UDID" \
        "$DERIVED" 2>&1 | tail -2

    echo "[3/8] Relaunching app..."
    xcrun devicectl device process launch --device "$DEVICE_UDID" \
        --terminate-existing "$APP_BUNDLE_ID" 2>&1 | tail -1
fi

echo "[4/8] Waiting 8s for tunnel to settle..."
sleep 8

if [[ "$SKIP_TRAFFIC" == "0" ]]; then
    echo "[5/8] Sending test traffic..."
    python3 "$(dirname "$0")/send_test_traffic.py" \
        --iface en0 --target-ip "$TARGET_IP"

    echo "[6/8] Waiting 4s for extension to log..."
    sleep 4
fi

echo "[7/8] Pulling logs..."
mkdir -p /tmp/columba-test
xcrun devicectl device copy from --device "$DEVICE_UDID" \
    --domain-type appGroupDataContainer --domain-identifier "$APP_GROUP_ID" \
    --source Library/Caches/ext_diag.log \
    --destination /tmp/columba-test/ext_diag.log 2>&1 | tail -1
xcrun devicectl device copy from --device "$DEVICE_UDID" \
    --domain-type appDataContainer --domain-identifier "$APP_BUNDLE_ID" \
    --source Documents/diag.log \
    --destination /tmp/columba-test/diag.log 2>&1 | tail -1

echo "[8/8] Verifying..."
fail=0

# Tunnel must be up.
if ! grep -q "enabled tunnel mode" /tmp/columba-test/diag.log; then
    echo "  FAIL: tunnel never reached enabled state"
    fail=1
else
    echo "  OK: tunnel reached enabled state"
fi

# When auto is in tunnel mode (future), expect HELLO and listener
# accept; for now, just confirm extension wrote anything.
if [[ -s /tmp/columba-test/ext_diag.log ]]; then
    echo "  OK: extension diag log written ($(wc -l < /tmp/columba-test/ext_diag.log) lines)"
else
    echo "  WARN: extension diag log empty"
fi

# When auto-in-extension is back, uncomment:
#if grep -q "data listener accepted" /tmp/columba-test/ext_diag.log; then
#    echo "  OK: extension's NWListener accepted inbound from $TARGET_IP"
#else
#    echo "  FAIL: extension's NWListener never saw inbound — sandbox probably blocking"
#    fail=1
#fi

if [[ "$fail" == "1" ]]; then
    echo
    echo "FAIL"
    exit 1
fi
echo
echo "OK"
