#!/usr/bin/env python3
"""Faithful backbone probe: boot RNS from a config file, EXACTLY like the app.

Earlier versions constructed TCPClientInterface directly, which bypasses the
`interface_post_init` that Reticulum runs for config-loaded interfaces (where
`announce_rate_target`, `ifac_size`, etc. get set). That made the receive path
crash with AttributeErrors that the real phone does NOT hit. This version
writes a config file with the same TCP client the phone uses and lets
`RNS.Reticulum(config_dir)` bring the interface up through the real path.

It then announces itself, watches inbound announces for WATCH seconds, and
reports whether the PHONE's destination hash is among the peers heard.

Usage:
  probe_backbone.py --host 10.0.4.63 --port 4243 --watch 50 \
                    --phone-dest 112b6271fd61bfb14500eaf95ed30749
"""

import argparse
import os
import tempfile
import time

import RNS
import LXMF


def log(m):
    print(f"[probe] {m}", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--watch", type=float, default=50.0)
    p.add_argument("--phone-dest", default="",
                   help="phone destination hash to look for among inbound announces")
    p.add_argument("--phone-name", default="Torlando - Columba",
                   help="phone display name to look for")
    p.add_argument("--send-to", default="",
                   help="destination hash (hex) to send an LXMF message to, "
                        "to test hub->that-node delivery from a fresh connection")
    p.add_argument("--send-text", default="probe->you: hub delivery test")
    args = p.parse_args()

    config_dir = tempfile.mkdtemp(prefix="probe-rns-cfg-")
    config_path = os.path.join(config_dir, "config")
    with open(config_path, "w") as f:
        f.write(
            "[reticulum]\n"
            "  enable_transport = no\n"
            "  share_instance = no\n"
            "  panic_on_interface_error = no\n"
            "  discover_interfaces = no\n"
            "  autoconnect_discovered_interfaces = 0\n"
            "\n"
            "[logging]\n"
            "  loglevel = 4\n"
            "\n"
            "[interfaces]\n"
            "  [[probe-tcp]]\n"
            "    enabled = yes\n"
            "    interface_enabled = yes\n"
            "    mode = full\n"
            "    type = TCPClientInterface\n"
            f"    target_host = {args.host}\n"
            f"    target_port = {args.port}\n"
        )

    import signal as _s
    _o = _s.signal
    _s.signal = lambda *a, **k: None
    try:
        reticulum = RNS.Reticulum(config_dir)
        identity = RNS.Identity()
        log(f"probe identity={identity.hash.hex()[:16]}")

        storage = os.path.join(config_dir, "lxmf-storage")
        os.makedirs(storage, exist_ok=True)
        router = LXMF.LXMRouter(identity=identity, storagepath=storage)

        seen = []
        phone_seen = []

        class AH:
            aspect_filter = None
            receive_path_responses = True

            def received_announce(self, destination_hash, announced_identity, app_data,
                                  announce_packet_hash=None, is_path_response=False):
                name = None
                try:
                    name = LXMF.display_name_from_app_data(app_data)
                except Exception:
                    pass
                seen.append((destination_hash.hex(), name))
                is_phone = (args.phone_dest and destination_hash.hex().startswith(args.phone_dest[:16]))
                if is_phone:
                    phone_seen.append((destination_hash.hex(), name))
                    log(f">>> PHONE ANNOUNCE dest={destination_hash.hex()[:16]} name={name!r}")
                else:
                    log(f"ANNOUNCE dest={destination_hash.hex()[:16]} name={name!r}")

        RNS.Transport.register_announce_handler(AH())

        def on_msg(message):
            src = message.source_hash.hex() if message.source_hash else "?"
            try:
                txt = message.content_as_string()
            except Exception:
                txt = "<binary>"
            log(f"DELIVERY from={src[:16]} text={txt!r}")
        router.register_delivery_callback(on_msg)

        dest = router.register_delivery_identity(identity, display_name="smoke-probe")
        log(f"probe delivery dest={dest.hash.hex()[:16]}")

        deadline = time.time() + args.watch
        announced = False
        sent = False
        while time.time() < deadline:
            if not announced:
                try:
                    online = [i.name for i in RNS.Transport.interfaces if getattr(i, "online", False)]
                    if online:
                        dest.announce()
                        announced = True
                        log(f"announced. online_interfaces={online}")
                except Exception as e:
                    log(f"announce attempt error: {e}")
            if args.send_to and not sent and announced:
                try:
                    dhash = bytes.fromhex(args.send_to)
                    d = RNS.Destination(dhash)
                    m = LXMF.LXMessage(d, dest, content=args.send_text.encode())
                    m.send()
                    sent = True
                    log(f"SENT to {args.send_to[:16]} text={args.send_text!r}")
                except Exception as e:
                    log(f"send error: {e!r}")
                    sent = True
            time.sleep(2)

        online = [i.name for i in RNS.Transport.interfaces if getattr(i, "online", False)]
        log(f"DONE online={online} total_announces_seen={len(seen)} phone_announces_seen={len(phone_seen)}")
        distinct = sorted({a[0] for a in seen})
        log(f"distinct_peers={len(distinct)}")
        for h in distinct:
            tag = " <== PHONE" if (args.phone_dest and h.startswith(args.phone_dest[:16])) else ""
            log(f"  peer {h[:16]}{tag}")
        log(f"RESULT: phone_dest_in_inbound={'YES' if phone_seen else 'NO'}")
    finally:
        _s.signal = _o
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
