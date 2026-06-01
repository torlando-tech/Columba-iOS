#!/usr/bin/env python3
"""Headless LXST voice caller — dials the iOS Columba sim's telephony
destination so its incoming-call / CallKit path fires, for debugging the
"call screen dismisses + reappears as Unknown" bug on the sim (full log access).

Uses Sideband's own ReticulumTelephone (which wraps LXST.Telephone), so it's
wire-identical to a Sideband user placing the call. Joins the host's shared
RNS instance (lxmd) exactly like the interop peer, so it shares Columba's
transport.

Usage:
  PYTHONPATH unneeded — paths injected below.
  python3 voice_caller.py <columba_identity_hex> [ring_seconds]
"""
import sys, os, time, threading

sys.path.insert(0, os.path.expanduser("~/repos/LXST"))
sys.path.insert(0, os.path.expanduser("~/repos/Sideband"))

import RNS  # noqa: E402
from sbapp.sideband.voice import ReticulumTelephone  # noqa: E402

COLUMBA_ID_HEX = sys.argv[1] if len(sys.argv) > 1 else "695f23533fe3547183f1b550d8552ae8"
RING_SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 25


def main():
    RNS.Reticulum()  # connect to the shared lxmd instance (share_instance=Yes)
    identity = RNS.Identity()
    print(f"[caller] my identity={RNS.prettyhexrep(identity.hash)}", flush=True)

    phone = ReticulumTelephone(identity, owner=None)
    # NB: don't call phone.start() — its run() loop is Sideband hw-state polling
    # and isn't present on this build; the wrapped LXST.Telephone drives the
    # call protocol itself. We just need to keep the process alive.
    time.sleep(1.0)

    phone.announce()  # so Columba can resolve/path us (matches the 'correct name' case)
    print("[caller] announced own telephony", flush=True)

    id_bytes = bytes.fromhex(COLUMBA_ID_HEX)
    tel_dest = RNS.Destination.hash_from_name_and_identity("lxst.telephony", id_bytes)
    print(f"[caller] Columba telephony dest = {tel_dest.hex()}", flush=True)

    if not RNS.Transport.has_path(tel_dest):
        RNS.Transport.request_path(tel_dest)
        deadline = time.time() + 30
        while not RNS.Transport.has_path(tel_dest) and time.time() < deadline:
            time.sleep(0.5)
    if not RNS.Transport.has_path(tel_dest):
        print("[caller] NO PATH to Columba telephony after 30s — is the sim "
              "announcing lxst.telephony + bridged through lxmd? aborting.", flush=True)
        return 1
    print(f"[caller] path to telephony resolved ({RNS.Transport.hops_to(tel_dest)} hops); DIALING", flush=True)

    result = phone.dial(id_bytes)
    print(f"[caller] dial() -> {result}", flush=True)

    # state: 0=AVAILABLE 1=CONNECTING 2=RINGING 3=IN_CALL (is_* are @property, no parens)
    _names = {0: "AVAILABLE", 1: "CONNECTING", 2: "RINGING", 3: "IN_CALL"}
    for i in range(RING_SECONDS):
        st = phone.state
        print(f"[caller] t={i:>2}s state={st}({_names.get(st, '?')})", flush=True)
        time.sleep(1.0)

    print("[caller] hanging up", flush=True)
    try:
        phone.hangup()
    except Exception as e:
        print(f"[caller] hangup error: {e}", flush=True)
    time.sleep(2.0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
