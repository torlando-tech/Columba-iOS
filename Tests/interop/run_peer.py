#!/usr/bin/env python3
"""
Headless Sideband peer for iOS Columba interop testing.

Boots a `SidebandCore` daemon in-process so we can:
  - announce on the same rnsd the iPhone is attached to,
  - receive LXMF messages from iOS Columba (verify the iOS→peer wire works),
  - send LXMF messages to iOS Columba (verify the iOS receive UI),
  - tap *every* inbound LXMessage (including ones Sideband filters out
    before its `lxm` table — e.g. malformed-but-decoded messages whose
    signature didn't validate). The tap is the diagnostic surface for
    the current `iOS-double-checks-but-Android-doesn't-receive` bug —
    if iOS messages reach the tap but get rejected before being shown,
    we see *exactly* why.

Usage:
  python run_peer.py                                    # default: print our hash, wait
  python run_peer.py --send <dest_hex> "hello"          # send one message, exit
  python run_peer.py --watch                            # print every inbound (taps + Sideband DB)
"""

from __future__ import annotations
import argparse
import os
import sys
import time

# peer_sideband.py imports from sbapp.* — the Sideband checkout needs to be on sys.path
# before it's imported. Override via `SIDEBAND_SRC` env when the checkout lives elsewhere.
SIDEBAND_SRC = os.environ.get("SIDEBAND_SRC", os.path.expanduser("~/repos/Sideband"))
sys.path.insert(0, SIDEBAND_SRC)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from peer_sideband import SidebandPeer  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=os.path.expanduser("~/.sideband-interop"),
                        help="persistent config dir (so identity_hex survives restarts)")
    parser.add_argument("--send", nargs=2, metavar=("DEST_HEX", "CONTENT"),
                        help="send one text message to DEST_HEX and exit")
    parser.add_argument("--watch", action="store_true",
                        help="print every inbound LXMessage observed via the tap")
    parser.add_argument("--idle-seconds", type=int, default=900,
                        help="how long to stay alive in watch / idle mode (default 15min)")
    args = parser.parse_args()

    os.makedirs(args.config, exist_ok=True)
    peer = SidebandPeer(sideband_src=SIDEBAND_SRC, config_dir=args.config)

    print(f"[peer] booting Sideband headless (config={args.config}) …", flush=True)
    peer.start(ready_timeout=60.0)
    print(f"[peer] identity_hex = {peer.identity_hex}", flush=True)
    print(f"[peer] announce sent; share this hex with the iPhone:", flush=True)
    print(f"[peer]   {peer.identity_hex}", flush=True)

    if args.send is not None:
        dest_hex, content = args.send
        print(f"[peer] sending text → {dest_hex[:8]}… : {content!r}", flush=True)
        ok = peer.send_text(dest_hex, content)
        print(f"[peer] send_text() returned {ok}", flush=True)
        # Give RNS a beat to actually send the packet before we tear down
        time.sleep(3.0)
        peer.stop()
        return 0

    # Idle / watch mode — print every inbound LXMessage.
    seen_taps = 0
    deadline = time.time() + args.idle_seconds
    print(f"[peer] watching for inbound … (Ctrl-C to exit, idle timeout {args.idle_seconds}s)", flush=True)
    try:
        while time.time() < deadline:
            taps = peer._taps  # noqa: SLF001 — purpose-built debug surface
            while seen_taps < len(taps):
                lxm = taps[seen_taps]
                seen_taps += 1
                # Print the full source LXMF delivery-destination hash + the
                # message hash so callers can match against the sender's
                # `[PY] started identity=… destination=…` log line and the
                # sender's `[PY] delivery <hash> state=delivered` line — that
                # three-way match is the rigorous "same message, same source,
                # signature valid" check the harness relies on.
                src_hex = lxm.source_hash.hex() if lxm.source_hash else "?"
                msg_hex = lxm.hash.hex() if getattr(lxm, "hash", None) else "?"
                content = (lxm.content or b"").decode("utf-8", errors="replace")
                sig_ok = getattr(lxm, "signature_validated", None)
                fields = lxm.fields or {}
                print(f"[peer]   ← inbound src={src_hex} "
                      f"msg_hash={msg_hex[:16]}… content={content!r} "
                      f"sig_validated={sig_ok} fields_keys={sorted(fields.keys())}",
                      flush=True)
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("[peer] interrupted, shutting down …", flush=True)

    peer.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
