#!/usr/bin/env python3
"""Seed a TCP client interface into the simulator app's group UserDefaults.

The smoke test needs the app's in-process RNS backend to connect to the local
smoke node over TCP. Driving the 2-step TCP discovery wizard in Maestro is
flaky and tests UI that is not the behavior under test, so instead we pre-seed
a TCP client interface into the app-group defaults (the prerequisite), then
drive the REAL UI for the round-trip (discovery -> contact -> send -> receive).

This writes a single `InterfaceEntity` (encoded exactly as the app's
`InterfaceRepository` does - plain JSON, default JSONEncoder date strategy)
under the `com.columba.interfaces` key of the `group.network.columba.Columba`
defaults suite. The app reads that key on backend start and brings the TCP
client interface up.

Usage:
    seed_interface.py --device <UDID> --host <IP> --port <PORT>
"""

import argparse
import base64
import json
import subprocess
import sys
import time
from pathlib import Path

STORAGE_KEY = "com.columba.interfaces"
GROUP_SUITE = "group.network.columba.Columba"
PLIST_NAME = "group.network.columba.Columba.plist"


def log(msg: str) -> None:
    print(f"[seed] {msg}", flush=True)


def swift_date_seconds(now: float) -> float:
    # JSONEncoder default date strategy: seconds since 2001-01-01 00:00:00 UTC.
    # 978307200 is the unix timestamp of 2001-01-01T00:00:00Z.
    return now - 978307200.0


def build_interface_json(host: str, port: int) -> bytes:
    now = time.time()
    entity = {
        "id": "smoke-tcp-client",
        "name": "Smoke TCP",
        "type": "TCPClient",
        "enabled": True,
        "mode": "full",
        "config": {
            "type": "tcpClient",
            "config": {
                "targetHost": host,
                "targetPort": port,
                "bootstrapOnly": False,
            },
        },
        "displayOrder": 0,
        "createdAt": swift_date_seconds(now),
        "updatedAt": swift_date_seconds(now),
    }
    return json.dumps([entity]).encode("utf-8")


def find_group_plist(device_udid: str) -> Path:
    base = Path.home() / (
        "Library/Developer/CoreSimulator/Devices/"
        f"{device_udid}/data/Containers/Shared/AppGroup"
    )
    if not base.is_dir():
        raise FileNotFoundError(f"app group base dir missing: {base}")
    matches = sorted(base.glob(f"*/Library/Preferences/{PLIST_NAME}"))
    if not matches:
        raise FileNotFoundError(f"no {PLIST_NAME} under {base}")
    if len(matches) > 1:
        log(f"WARNING: {len(matches)} candidate plists; using {matches[0]}")
    return matches[0]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--device", required=True, help="simulator UDID")
    p.add_argument("--host", required=True, help="host IP the app should connect to")
    p.add_argument("--port", type=int, required=True, help="smoke node TCP port")
    args = p.parse_args()

    plist = find_group_plist(args.device)
    log(f"group plist: {plist}")

    payload = build_interface_json(args.host, args.port)
    b64 = base64.b64encode(payload).decode("ascii")

    # Set a Data value in the plist. PlistBuddy cannot set Data directly, so we
    # build the value via plutil by writing a one-key plist and merging. The
    # most reliable cross-version path: rewrite the whole key via plutil -replace
    # using a Data (base64) literal. plutil's -replace accepts a base64 data
    # string when the existing type is data; to be safe we create a fresh key
    # with `defaults`-style data via a tiny intermediate plist.
    #
    # Approach: use `plutil` to add the key as data. plutil can read a plist
    # containing Data and `plutil -replace` a key with `$(cat ...)`. The
    # simplest reliable method on macOS: use `python3` + the plistlib module to
    # read-modify-write the file in place, preserving all other keys.
    import plistlib

    data = {}
    if plist.exists():
        with open(plist, "rb") as f:
            data = plistlib.load(f)

    data[STORAGE_KEY] = payload  # plistlib stores bytes as Data

    with open(plist, "wb") as f:
        plistlib.dump(data, f)

    log(f"wrote {STORAGE_KEY} ({len(payload)} bytes) to {plist.name}")

    # Verify by reading back.
    with open(plist, "rb") as f:
        check = plistlib.load(f)
    readback = check.get(STORAGE_KEY, b"")
    log(f"readback ok: {readback[:60]!r}..." if len(readback) > 60 else f"readback ok: {readback!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
