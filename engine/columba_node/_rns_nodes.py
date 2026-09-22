"""Two-node RNS helpers for the engine integration test (Mac / RNS only).

The production ``app/rns_bridge.py`` has process-global state (one Reticulum +
router per process), so a sender and receiver cannot share a process. This
module provides a self-contained receiver that runs in its OWN subprocess and a
small in-process node factory used to build each side. Importing RNS/LXMF here
is guarded: on a machine without RNS (the Linux controller) ``import RNS``
raises and the integration test is SKIPPED, not failed.

Only RNS + LXMF are imported (never app.rns_bridge), so this stays isolated
from the app's embedded-interpreter bridge.
"""

from __future__ import annotations

import os
import tempfile

import RNS
import LXMF


def make_node(config_dir: str, identity_path: str, display_name: str,
              listen_port: int) -> dict:
    """Bring up one RNS + LXMF node on a loopback TCP interface.

    Returns the local info: ``identity_hash`` / ``destination_hash`` (hex). The
    node announces on start so a peer that autoconnects to it can discover it.
    """
    os.makedirs(config_dir, exist_ok=True)
    identity = RNS.Identity()
    identity.to_file(identity_path)

    storage = os.path.join(config_dir, "lxmf-storage")
    os.makedirs(storage, exist_ok=True)
    router = LXMF.LXMRouter(identity=identity, storagepath=storage)
    destination = router.register_delivery_identity(identity, display_name=display_name)
    if destination is None:
        raise RuntimeError("register_delivery_identity returned None")

    iface = RNS.TCPClientInterface("127.0.0.1", listen_port,
                                   interface_name="loop")
    iface.connect()
    destination.announce()
    return {
        "identity_hash": identity.hash.hex(),
        "destination_hash": destination.hash.hex(),
    }


def _receiver_main() -> None:
    """Receiver entry point: bring up a node, publish its hashes, then block.

    Reads the config dir + peer-hash output path from the environment, writes
    the peer hashes (so the test process can read them), then sleeps so the
    test process has time to send.
    """
    config_dir = os.environ["RECV_CONFIG"]
    peer_out = os.environ["RECV_PEER_OUT"]
    info = make_node(config_dir, os.path.join(config_dir, "identity"),
                     "Columba-Recv", int(os.environ.get("RECV_PORT", "30001")))
    with open(peer_out, "w", encoding="utf-8") as fh:
        fh.write(info["identity_hash"])
    import time
    time.sleep(float(os.environ.get("RECV_HOLD", "30")))


if __name__ == "__main__":
    _receiver_main()
