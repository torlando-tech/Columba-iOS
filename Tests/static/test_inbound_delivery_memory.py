"""Inbound delivery memory contract (background-transport crash, 6 MB attachment).

The Network Extension runs the Python RNS node inside a tight jetsam budget
(idle ~14 MB; the whole Model-B epic gates on surviving delivery peaks). Two
amplifications in `app/rns_bridge.py` killed the extension mid-transfer for a
multi-megabyte attachment:

1. `_delivery_callback` computed `umsgpack.packb(fields).hex()` (~3x the
   attachment size) even in durable (NE) mode, where the hex is never read —
   the NE persists the LXMF wire (`message.packed`) directly into the shared
   GRDB store.
2. The ingress-retry retention path hex-encoded the whole `packed` wire and
   `json.dumps`-ed it as one string (~4x again), on the exact path that runs
   when the process is already under pressure.

These tests load the real functions out of `app/rns_bridge.py` in an isolated
namespace (same extraction pattern as `test_rns_bridge_persistence.py`) and
assert the behavioural contract: durable mode never touches umsgpack, the
in-process path still carries `fields_hex`, and the retained JSONL artifact
round-trips byte-exactly through the chunked writer.
"""

import ast
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import types
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"

_CALLBACK_FNS = [
    "_canonical_inbound_hash",
    "_inbound_delivery_method_name",
    "_receiving_interface",
    "_signal_metrics",
    "_delivery_callback",
]

_ARTIFACT_FNS = [
    "_ingress_retry_path",
    "_ingress_retry_fields",
    "_store_ingress_retry_artifact",
    "_reconstruct_ingress_message",
]


def _extract(names):
    tree = ast.parse(BRIDGE.read_text())
    wanted = set(names)
    return [n for n in tree.body if
            isinstance(n, ast.FunctionDef) and n.name in wanted or
            isinstance(n, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id in wanted for t in n.targets)]


class RecordingUmsgpack:
    """Stand-in for `RNS.vendor.umsgpack` that records packb calls."""

    def __init__(self):
        self.packb_calls = []

    def packb(self, obj):
        self.packb_calls.append(obj)
        return b"\xc1fake-packed"


def _callback_message(fields=None):
    msg = types.SimpleNamespace()
    msg.method = 0x01  # OPPORTUNISTIC
    msg.fields = fields
    msg.source_hash = bytes.fromhex("11" * 16)
    msg.hash = bytes.fromhex("22" * 32)
    msg.message_id = msg.hash
    msg.packed = b"\x01packed-wire"
    msg.rssi = None
    msg.snr = None
    msg.q = None

    def content_as_string():
        return "big file incoming"

    def title_as_string():
        return ""

    msg.content_as_string = content_as_string
    msg.title_as_string = title_as_string
    return msg


class DeliveryCallbackDurableModeTest(unittest.TestCase):
    """Durable (NE) delivery must not materialise the MessagePack-hex field map."""

    def setUp(self):
        # `_delivery_callback` reaches umsgpack via `from RNS.vendor import
        # umsgpack`, which resolves through the import system, not the exec
        # namespace — register the stub modules for the duration of the test.
        self._saved_rns = {
            name: sys.modules.get(name) for name in ("RNS", "RNS.vendor")
        }

    def tearDown(self):
        for name, mod in self._saved_rns.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod

    def _load(self, *, durable, umsgpack, events):
        rns_mod = types.ModuleType("RNS")
        rns_mod.LOG_ERROR = 1
        rns_mod.LOG_DEBUG = 2
        rns_mod.log = lambda *_args: None
        rns_mod.Transport = types.SimpleNamespace(path_table={})
        vendor_mod = types.ModuleType("RNS.vendor")
        vendor_mod.umsgpack = umsgpack
        rns_mod.vendor = vendor_mod
        sys.modules["RNS"] = rns_mod
        sys.modules["RNS.vendor"] = vendor_mod
        ns = {
            "Any": Any,
            "time": time,
            "LXMF": types.SimpleNamespace(
                LXMessage=types.SimpleNamespace(
                    OPPORTUNISTIC=0x01, DIRECT=0x02, PROPAGATED=0x03, PAPER=0x04,
                ),
            ),
            "RNS": rns_mod,
            "_put": lambda kind, **payload: events.append(("put", (kind, payload))),
            "_durable_mode": durable,
            "_block_unknown_senders": False,
            "_write_inbound_to_grdb": lambda message: events.append(("grdb", message)) or True,
            "_retry_pending_ingress": lambda: events.append(("retry", None)) or 0,
            "_is_telemetry_only_inbound": lambda message: False,
            "_publish_inbound_banner": lambda message: events.append(("banner", None)),
            "_post_darwin": lambda name: events.append(("darwin", name)),
            "_DARWIN_NEW_MESSAGE": "newMessage",
        }
        exec(
            compile(ast.Module(body=_extract(_CALLBACK_FNS), type_ignores=[]), str(BRIDGE), "exec"),
            ns,
        )
        return ns["_delivery_callback"]

    def test_durable_mode_skips_field_map_packing_and_inbox(self):
        """The NE path persists to GRDB and must never allocate packb+hex or
        enqueue the legacy `_put` inbox event."""
        events = []
        umsgpack = RecordingUmsgpack()
        callback = self._load(durable=True, umsgpack=umsgpack, events=events)
        fields = {0x05: [["big.bin", b"\x00" * 4096]]}

        callback(_callback_message(fields=fields))

        self.assertEqual([], umsgpack.packb_calls,
                         "durable mode must not packb the field map (multi-MB transient in the NE)")
        kinds = [kind for kind, _ in events]
        self.assertNotIn("put", kinds, "durable mode must not enqueue the legacy inbox event")
        self.assertIn("grdb", kinds, "durable mode must persist into the shared GRDB store")
        self.assertIn("banner", kinds)
        self.assertIn(("darwin", "newMessage"), events)

    def test_inprocess_mode_still_carries_fields_hex(self):
        """The foreground path still hands Swift the MessagePack-hex field map."""
        events = []
        umsgpack = RecordingUmsgpack()
        callback = self._load(durable=False, umsgpack=umsgpack, events=events)
        fields = {0x05: [["big.bin", b"\x00" * 4096]]}

        callback(_callback_message(fields=fields))

        self.assertEqual(1, len(umsgpack.packb_calls),
                         "the in-process path must still packb the field map exactly once")
        puts = [payload for kind, payload in events if kind == "put"]
        self.assertEqual(1, len(puts))
        kind, payload = puts[0]
        self.assertEqual("inbound", kind)
        self.assertEqual(b"\xc1fake-packed".hex(), payload["fields_hex"])


class IngressRetryArtifactRoundTripTest(unittest.TestCase):
    """The chunked JSONL writer must be byte-exact against the reader."""

    def _build(self):
        ns = {
            "Any": Any,
            "os": os,
            "json": json,
            "time": time,
            "types": types,
            "threading": threading,
            "RNS": types.SimpleNamespace(log=lambda *a, **k: None, LOG_ERROR=0, LOG_DEBUG=1),
            "_grdb_path": None,
            "_ingress_retry_lock": threading.Lock(),
            "_is_telemetry_only_inbound": lambda message: False,
        }
        exec(
            compile(ast.Module(body=_extract(_ARTIFACT_FNS), type_ignores=[]), str(BRIDGE), "exec"),
            ns,
        )
        return ns

    def _dir(self):
        d = Path(tempfile.mkdtemp(prefix="rns_artifact_"))
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        return d

    def test_large_packed_round_trips_through_chunked_writer(self):
        ns = self._build()
        store_dir = self._dir()
        ns["_grdb_path"] = str(store_dir / "lxmf-swift.db")

        # Larger than the writer's hex chunk: forces the multi-chunk path.
        big_packed = os.urandom(3 * 1024 * 1024 + 17)
        message = types.SimpleNamespace(
            packed=big_packed,
            hash=b"cc" * 32,
            source_hash=b"aa" * 32,
            destination_hash=b"bb" * 32,
            title=b"t",
            content=b"payload",
            signature=b"sig",
            stamp=b"\x00\x01\x02",
            timestamp=1234.5,
            method=4,
            rssi=-71.5,
            snr=6.25,
            q=0.9,
        )

        fields = ns["_ingress_retry_fields"](message)
        self.assertIsNotNone(fields)
        ns["_store_ingress_retry_artifact"](fields)

        path = ns["_ingress_retry_path"]()
        with open(path, "r", encoding="utf-8") as fh:
            lines = [ln for ln in fh.read().splitlines() if ln.strip()]
        self.assertEqual(1, len(lines))

        payload = json.loads(lines[0])
        self.assertEqual(big_packed, bytes.fromhex(payload["packed_hex"]),
                         "chunked hex writing must reproduce the packed wire byte-exactly")
        self.assertEqual((b"aa" * 32).hex(), payload["source_hash_hex"])
        self.assertEqual((b"bb" * 32).hex(), payload["destination_hash_hex"])
        self.assertEqual((b"cc" * 32).hex(), payload["message_id_hex"])
        self.assertEqual((b"\x00\x01\x02").hex(), payload["stamp_hex"])
        self.assertEqual(1234.5, payload["timestamp"])
        self.assertEqual(4, payload["method"])
        self.assertEqual(-71.5, payload["rssi"])
        self.assertEqual(6.25, payload["snr"])
        self.assertEqual(0.9, payload["q"])
        self.assertFalse(payload["skip_conversation"])

        holder = ns["_reconstruct_ingress_message"](payload)
        self.assertEqual(big_packed, holder.packed)
        self.assertEqual(message.content, holder.content)
        self.assertEqual(message.stamp, holder.stamp)

    def test_empty_blobs_and_null_stamp_stay_valid_json(self):
        ns = self._build()
        store_dir = self._dir()
        ns["_grdb_path"] = str(store_dir / "lxmf-swift.db")

        message = types.SimpleNamespace(
            packed=b"\x01",
            hash=b"cc" * 32,
            source_hash=b"aa" * 32,
            destination_hash=b"bb" * 32,
            title=b"",
            content=b"",
            signature=b"",
            stamp=None,
            timestamp=1.0,
            method=0,
            rssi=None,
            snr=None,
            q=None,
        )
        fields = ns["_ingress_retry_fields"](message)
        ns["_store_ingress_retry_artifact"](fields)

        with open(ns["_ingress_retry_path"](), "r", encoding="utf-8") as fh:
            payload = json.loads(fh.readline())
        self.assertEqual("", payload["title_hex"])
        self.assertEqual("", payload["content_hex"])
        self.assertEqual("", payload["signature_hex"])
        self.assertIsNone(payload["stamp_hex"])
        self.assertIsNone(payload["rssi"])


if __name__ == "__main__":
    unittest.main()
