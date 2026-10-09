#!/usr/bin/env python3
"""Standalone RNS + LXMF smoke-test peer node.

Runs on the test host (Mac in local dev, CI runner in CI) and listens for a
Columba client over RNS TCP. It announces itself as a peer so the app's
Contacts > Network tab shows it, records every LXMF it receives to a JSON
inbox file, and sends a reply back to the sender.

The orchestrator (run_smoke.sh) starts this, drives the app with Maestro,
then checks the inbox to prove the round-trip happened.

Usage:
    smoke_node.py --listen-ip 0.0.0.0 --port 4242 --display-name "Smoke Test Node" \
                  --inbox /tmp/smoke_inbox.json

The RNS/LXMF package tree must be importable via PYTHONPATH. In local dev
the orchestrator sets it to the cloned Torlando forks at the exact pinned
refs (same as the app's bundled wheels). In CI, `support/fetch-wheels.sh`
already produces a working interpreter.

This node intentionally has no state beyond its own RNS config dir and the
inbox file. It is safe to run many times; each run overwrites the inbox.
"""

import argparse
import json
import os
import sys
import tempfile
import threading
import time

# Import RNS/LXMF from PYTHONPATH (the orchestrator sets this to the pinned
# Torlando forks). Fail loudly if missing - do not silently fall back to a
# different version, which is a classic silent-fail in the RNS transport.
import RNS  # noqa: E402
import RNS.Interfaces  # noqa: E402, F401
import LXMF  # noqa: E402

# TCPServerInterface lives in the TCPInterface submodule in this RNS fork and
# is not re-exported at the RNS.Interfaces top level in every version. Try the
# submodule first, then the top-level, so the node works across both.
try:
    from RNS.Interfaces.TCPInterface import TCPServerInterface  # noqa: E402
except ImportError:  # pragma: no cover - older RNS layout
    TCPServerInterface = RNS.Interfaces.TCPServerInterface


def log(msg: str) -> None:
    print(f"[smoke-node] {msg}", flush=True)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Columba smoke-test RNS/LXMF peer node")
    p.add_argument("--listen-ip", default="0.0.0.0", help="IP for the TCP server interface")
    p.add_argument("--port", type=int, default=4242, help="port for the TCP server interface")
    p.add_argument("--display-name", default="Smoke Test Node",
                   help="name the app shows in the Network tab")
    p.add_argument("--inbox", required=True,
                   help="path to the JSON inbox file (overwritten on first write)")
    p.add_argument("--reply-text", default="smoke reply from node",
                   help="text the node sends back when it receives a message")
    p.add_argument("--announce-period", type=float, default=3.0,
                   help="seconds between re-announces (keep the app's path entry fresh)")
    p.add_argument("--ready-file", default=None,
                   help="optional: touch this file once the node is up (orchestrator readiness signal)")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # Fresh config dir so repeated runs never collide on a stale identity.
    config_dir = tempfile.mkdtemp(prefix="columba-smoke-node-")
    identity_path = os.path.join(config_dir, "identity.hex")

    # Stub out signal.signal the way the in-app rns_bridge does: RNS and LXMF
    # both call signal.signal for SIGINT/SIGTERM, which raises on a non-main
    # thread. We run single-threaded on main here, so this is a no-op, but it
    # makes the node portable to a worker thread without extra work.
    import signal as _signal
    _orig_signal = _signal.signal
    _signal.signal = lambda *_a, **_kw: None

    try:
        reticulum = RNS.Reticulum(config_dir)
        identity = RNS.Identity()
        identity.to_file(identity_path)
        log(f"identity={identity.hash.hex()}")

        storage_path = os.path.join(config_dir, "lxmf-storage")
        os.makedirs(storage_path, exist_ok=True)
        router = LXMF.LXMRouter(identity=identity, storagepath=storage_path)

        inbox_path = args.inbox
        inbox_lock = threading.Lock()
        reply_lock = threading.Lock()

        def delivery_callback(message):
            # message is an LXMF.LXMessage. Mirror app/rns_bridge.py's
            # _delivery_callback accessors (content_as_string, source_hash).
            sender_hash = message.source_hash.hex() if message.source_hash else "unknown"
            try:
                text = message.content_as_string()
            except Exception as e:  # pragma: no cover - defensive
                text = f"<undecodable content: {e}>"
            msg_hash = message.hash.hex() if message.hash else ""

            with inbox_lock:
                entry = {
                    "ts": time.time(),
                    "sender_hash": sender_hash,
                    "text": text,
                    "hash": msg_hash,
                }
                existing = []
                if os.path.isfile(inbox_path):
                    try:
                        with open(inbox_path) as f:
                            existing = json.load(f)
                    except Exception:
                        existing = []
                existing.append(entry)
                with open(inbox_path, "w") as f:
                    json.dump(existing, f, indent=2)

            log(f"RECEIVED from={sender_hash[:16]} text={text!r}")

            # Reply back to the sender. Do it on a worker thread so the
            # delivery callback returns quickly (RNS serialises delivery and a
            # blocking send would stall other inbound messages).
            def do_reply():
                with reply_lock:
                    try:
                        peer_identity = RNS.Identity.recall(
                            bytes.fromhex(sender_hash)
                        )
                        if peer_identity is None:
                            log(f"REPLY SKIPPED: sender {sender_hash[:16]} not in identity recall")
                            return
                        peer_dest = RNS.Destination(
                            peer_identity,
                            RNS.Destination.OUT,
                            RNS.Destination.SINGLE,
                            "lxmf",
                            "delivery",
                        )
                        # local_dest is the IN delivery destination returned by
                        # register_delivery_identity (same role as rns_bridge's
                        # _state["destination"]).
                        msg = LXMF.LXMessage(
                            peer_dest,
                            delivery_destination,
                            args.reply_text,
                            title="",
                            desired_method=LXMF.LXMessage.OPPORTUNISTIC,
                        )
                        msg.send()
                        log(f"REPLIED to={sender_hash[:16]} text={args.reply_text!r}")
                    except Exception as e:
                        import traceback
                        log(f"REPLY FAILED to={sender_hash[:16]}: {e}")
                        traceback.print_exc()

            threading.Thread(target=do_reply, daemon=True).start()

        router.register_delivery_callback(delivery_callback)
        delivery_destination = router.register_delivery_identity(
            identity, display_name=args.display_name
        )
        if delivery_destination is None:
            log("register_delivery_identity returned None")
            return 1
        dest_hash = delivery_destination.hash.hex()
        log(f"delivery dest={dest_hash[:16]} name={args.display_name!r}")

        # Write our own destination hash to a sidecar file so the orchestrator
        # can confirm the announce it expects is the one we emitted.
        dest_hash_path = inbox_path + ".dest"
        with open(dest_hash_path, "w") as f:
            f.write(dest_hash)

        # TCP server interface: the app's TCP client connects to us.
        iface = TCPServerInterface(
            reticulum,
            {
                "name": "smoke-server",
                "listen_ip": args.listen_ip,
                "listen_port": args.port,
            },
        )
        log(f"TCP server started on {args.listen_ip}:{args.port}")

        if args.ready_file:
            with open(args.ready_file, "w") as f:
                f.write(str(time.time()))
            log(f"ready-file written: {args.ready_file}")

        # Announce + keep re-announcing so the app's path entry stays fresh.
        delivery_destination.announce()
        log("initial announce sent")
        while True:
            time.sleep(args.announce_period)
            try:
                delivery_destination.announce()
            except Exception as e:
                log(f"re-announce failed: {e}")

    except Exception as e:
        import traceback
        log(f"FATAL: {e}")
        traceback.print_exc()
        return 1
    finally:
        _signal.signal = _orig_signal

    return 0


if __name__ == "__main__":
    sys.exit(main())
