"""The status poll must forward each interface's RNS announce-rate metrics.

`rns_bridge.status()` is the single source for Network Status rows in both
hosts (in-process foreground and NE proxy), so a missing/misnamed key
silently hides the "Announce In" / "Announce Out" rows or renders fabricated
zeros. The whole module cannot be imported here (iOS-only top-level side
effects), so the real `status` function is extracted and run in a seeded
namespace against fake interfaces.
"""

import ast
import threading
import types
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"


def _extract_status():
    tree = ast.parse(BRIDGE.read_text())
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == "status":
            return node
    raise AssertionError("status() not found in app/rns_bridge.py")


class _FakeIface:
    """Interface stand-in exposing the attributes `status()` reads."""

    def __init__(self, name="Auto_Discovery-1", rates=True):
        self.name = name
        self.online = True
        self.ifac_size = 16
        self.rxb = 10
        self.txb = 20
        self.autoconnect_hash = None
        self.adopted_interfaces = {"en0": object()}
        self.status_reason = None
        if rates:
            self.held_announces = {"a": object(), "b": object()}
            self.announce_rate_target = 3600

    def __str__(self):
        return f"AutoInterface[{self.name}]"

    def incoming_announce_frequency(self):
        return 0.15 if hasattr(self, "held_announces") else 0.0

    def outgoing_announce_frequency(self):
        return 2.5 if hasattr(self, "held_announces") else 0.0


class RnsBridgeAnnounceRatesTest(unittest.TestCase):
    def _status(self, *interfaces):
        ns = {
            "Any": object,
            "_lock": threading.RLock(),
            "_state": {"started": True},
            "RNS": types.SimpleNamespace(
                Transport=types.SimpleNamespace(
                    interfaces=list(interfaces),
                    destination_table={},
                    path_table={},
                )
            ),
        }
        exec(compile(ast.Module(body=[_extract_status()], type_ignores=[]),
                     str(BRIDGE), "exec"), ns)
        return ns["status"]()

    def test_forwards_rate_metrics_per_interface(self):
        result = self._status(_FakeIface())
        iface = result["interfaces"][0]

        self.assertEqual(iface["incoming_announce_frequency"], 0.15)
        self.assertEqual(iface["outgoing_announce_frequency"], 2.5)
        self.assertEqual(iface["announce_rate_target"], 3600)
        self.assertEqual(iface["held_announces"], 2)
        # The pre-existing contract keys stay intact.
        self.assertEqual(iface["adopted_count"], 1)
        self.assertIn("status_reason", iface)

    def test_missing_rate_api_defaults_to_quiet_values(self):
        result = self._status(_FakeIface(rates=False))
        iface = result["interfaces"][0]

        self.assertEqual(iface["incoming_announce_frequency"], 0.0)
        self.assertEqual(iface["outgoing_announce_frequency"], 0.0)
        self.assertIsNone(iface["announce_rate_target"])
        self.assertEqual(iface["held_announces"], 0)


if __name__ == "__main__":
    unittest.main()
