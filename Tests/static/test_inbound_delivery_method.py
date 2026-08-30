import ast
import types
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"


class FakeMessage:
    OPPORTUNISTIC = 0x01
    DIRECT = 0x02
    PROPAGATED = 0x03
    PAPER = 0x04

    def __init__(self, method: int):
        self.method = method
        self.fields = None
        self.source_hash = bytes.fromhex("11" * 16)
        self.hash = bytes.fromhex("22" * 32)
        self.message_id = self.hash
        self.packed = None

    def content_as_string(self) -> str:
        return "received through relay"

    def title_as_string(self) -> str:
        return ""


class InboundDeliveryMethodTests(unittest.TestCase):
    def load_callback(self, events):
        tree = ast.parse(BRIDGE.read_text(encoding="utf-8"))
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
            and node.name in {
                "_canonical_inbound_hash",
                "_inbound_delivery_method_name",
                "_receiving_interface",
                "_signal_metrics",
                "_delivery_callback",
            }
        }
        self.assertEqual(
            {
                "_canonical_inbound_hash",
                "_inbound_delivery_method_name",
                "_receiving_interface",
                "_signal_metrics",
                "_delivery_callback",
            },
            set(functions),
        )
        namespace = {
            "Any": Any,
            "LXMF": types.SimpleNamespace(LXMessage=FakeMessage),
            "RNS": types.SimpleNamespace(
                LOG_ERROR=1,
                LOG_DEBUG=2,
                log=lambda *_args: None,
                Transport=types.SimpleNamespace(path_table={}),
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

    def test_propagated_inbound_callback_preserves_delivery_method(self):
        events = []
        callback = self.load_callback(events)

        callback(FakeMessage(FakeMessage.PROPAGATED))

        self.assertEqual(1, len(events))
        kind, payload = events[0]
        self.assertEqual("inbound", kind)
        self.assertEqual("propagated", payload.get("method"))
        self.assertEqual("22" * 32, payload["message_hash"])

    def test_inbound_callback_maps_all_supported_delivery_methods(self):
        for value, expected in (
            (FakeMessage.OPPORTUNISTIC, "opportunistic"),
            (FakeMessage.DIRECT, "direct"),
            (FakeMessage.PROPAGATED, "propagated"),
            (FakeMessage.PAPER, "paper"),
            (0x7F, ""),
        ):
            with self.subTest(method=value):
                events = []
                callback = self.load_callback(events)
                callback(FakeMessage(value))
                self.assertEqual(expected, events[0][1].get("method"))


if __name__ == "__main__":
    unittest.main()
