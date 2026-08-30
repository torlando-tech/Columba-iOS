import ast
import types
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"

_REQUIRED_HELPERS = {
    "_canonical_inbound_hash",
    "_inbound_delivery_method_name",
    "_receiving_interface",
    "_signal_metrics",
    "_delivery_callback",
}


class FakeMessage:
    OPPORTUNISTIC = 0x01
    DIRECT = 0x02
    PROPAGATED = 0x03
    PAPER = 0x04

    def __init__(
        self,
        method: int = 0x01,
        receiving_interface: Any = None,
        source_hash: bytes = bytes.fromhex("11" * 16),
    ):
        self.method = method
        self.fields = None
        self.source_hash = source_hash
        self.hash = bytes.fromhex("22" * 32)
        self.message_id = self.hash
        self.packed = None
        if receiving_interface is not None:
            self.receiving_interface = receiving_interface

    def content_as_string(self) -> str:
        return "received through relay"

    def title_as_string(self) -> str:
        return ""


class RNodeLikeInterface:
    """Mirrors IOSRNodeInterface: exposes get_rssi() + get_snr()."""

    def __init__(self, rssi: int, snr: float):
        self._rssi = rssi
        self._snr = snr

    def get_rssi(self) -> int:
        return self._rssi

    def get_snr(self) -> float:
        return self._snr


class BLEPeerInterface:
    """Mirrors ble_reticulum.BLEPeerInterface: no get_rssi of its own, but
    carries a parent_interface that does (the IOSBLEInterface)."""

    def __init__(self, parent):
        self.parent_interface = parent
        self.peer_address = "AA:BB:CC:DD:EE:FF"


class BLEParentInterface:
    def __init__(self, rssi: int):
        self._rssi = rssi

    def get_rssi(self) -> int:
        return self._rssi


class TCPInterface:
    """No signal-metric methods at all (like a TCP / Auto / Backbone iface)."""


class RaisingRssiInterface:
    def get_rssi(self) -> int:
        raise RuntimeError("radio went away")

    def get_snr(self) -> float:
        return 3.5


class InboundSignalMetricsTests(unittest.TestCase):
    def _load(self, events, path_table=None, receiving_via_annotation=True):
        tree = ast.parse(BRIDGE.read_text(encoding="utf-8"))
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name in _REQUIRED_HELPERS
        }
        self.assertEqual(_REQUIRED_HELPERS, set(functions))
        path_table = dict(path_table or {})
        namespace = {
            "Any": Any,
            "LXMF": types.SimpleNamespace(LXMessage=FakeMessage),
            "RNS": types.SimpleNamespace(
                LOG_ERROR=1,
                LOG_DEBUG=2,
                log=lambda *_args: None,
                Transport=types.SimpleNamespace(path_table=path_table),
            ),
            "_put": lambda kind, **payload: events.append((kind, payload)),
        }
        module = ast.Module(
            body=[
                functions["_canonical_inbound_hash"],
                functions["_inbound_delivery_method_name"],
                functions["_receiving_interface"],
                functions["_signal_metrics"],
                functions["_delivery_callback"],
            ],
            type_ignores=[],
        )
        exec(compile(module, str(BRIDGE), "exec"), namespace)
        return namespace["_delivery_callback"]

    def test_rnode_inbound_carries_rssi_and_snr(self):
        events = []
        callback = self._load(events)
        iface = RNodeLikeInterface(rssi=-72, snr=6.25)
        callback(FakeMessage(receiving_interface=iface))

        self.assertEqual(1, len(events))
        kind, payload = events[0]
        self.assertEqual("inbound", kind)
        self.assertEqual(-72, payload["rssi"])
        self.assertAlmostEqual(6.25, payload["snr"])
        # Existing keys are preserved verbatim alongside the new metrics.
        self.assertEqual("22" * 32, payload["message_hash"])
        self.assertEqual("11" * 16, payload["source_hash"])
        self.assertEqual("opportunistic", payload["method"])
        self.assertIn("fields_hex", payload)

    def test_ble_peer_interface_resolves_rssi_via_parent(self):
        events = []
        callback = self._load(events)
        # BLEPeerInterface has no get_rssi; the parent (IOSBLEInterface) does.
        parent = BLEParentInterface(rssi=-80)
        peer = BLEPeerInterface(parent)
        callback(FakeMessage(receiving_interface=peer))

        self.assertEqual(1, len(events))
        _, payload = events[0]
        self.assertEqual(-80, payload["rssi"])
        # BLE has no SNR on any platform.
        self.assertIsNone(payload["snr"])

    def test_tcp_inbound_has_no_metrics_but_still_emits(self):
        events = []
        callback = self._load(events)
        callback(FakeMessage(receiving_interface=TCPInterface()))

        self.assertEqual(1, len(events))
        kind, payload = events[0]
        self.assertEqual("inbound", kind)
        self.assertIsNone(payload["rssi"])
        self.assertIsNone(payload["snr"])
        self.assertEqual("22" * 32, payload["message_hash"])

    def test_missing_receiving_interface_yields_none_metrics(self):
        events = []
        callback = self._load(events)
        # No receiving_interface annotation and no path_table entry.
        callback(FakeMessage())
        self.assertEqual(1, len(events))
        _, payload = events[0]
        self.assertIsNone(payload["rssi"])
        self.assertIsNone(payload["snr"])

    def test_path_table_fallback_resolves_interface(self):
        events = []
        src = bytes.fromhex("33" * 16)
        rnode = RNodeLikeInterface(rssi=-64, snr=10.0)
        # path_table entry: index 5 is the receiving Interface object.
        path_table = {src: [0, 0, 1, 0, None, rnode, None]}
        callback = self._load(events, path_table=path_table)
        # Message carries NO receiving_interface annotation, only a
        # source_hash, so the callback must fall back to path_table[src][5].
        callback(FakeMessage(source_hash=src))

        self.assertEqual(1, len(events))
        _, payload = events[0]
        self.assertEqual(-64, payload["rssi"])
        self.assertAlmostEqual(10.0, payload["snr"])

    def test_rssi_getter_raising_falls_back_to_none_without_raising(self):
        events = []
        callback = self._load(events)
        # get_rssi raises, get_snr still works. The exception must be swallowed
        # (delivery must not wedge) and rssi must be None.
        iface = RaisingRssiInterface()
        callback(FakeMessage(receiving_interface=iface))

        self.assertEqual(1, len(events))
        _, payload = events[0]
        self.assertIsNone(payload["rssi"])
        self.assertAlmostEqual(3.5, payload["snr"])

    def test_signal_metrics_none_interface_returns_none_pair(self):
        # Direct unit check of the helper for the None-interface fast path.
        tree = ast.parse(BRIDGE.read_text(encoding="utf-8"))
        fn = next(
            node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_signal_metrics"
        )
        namespace = {"Any": Any, "RNS": types.SimpleNamespace(log=lambda *_a: None)}
        exec(compile(ast.Module(body=[fn], type_ignores=[]), str(BRIDGE), "exec"), namespace)
        self.assertEqual((None, None), namespace["_signal_metrics"](None))


if __name__ == "__main__":
    unittest.main()
