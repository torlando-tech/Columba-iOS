"""Unit test for `discovery_json()` in app/rns_bridge.py (issue #193, T-B).

Runs WITHOUT a live RNS: `sys.modules['RNS']` and `sys.modules['LXMF']` are
patched with lightweight stubs BEFORE `app.rns_bridge` is imported (the module
does a top-level `import RNS` / `import LXMF`, which the stubs satisfy), then
the real `discovery_json()` from the imported module is exercised end-to-end
(JSON shape, bytes→hex coercion, enabled flag, autoconnected endpoints, and
the not-started empty shape).

Run from the worktree root:
    python3 -m pytest tests/test_rns_bridge_discovery.py -q
    python3 tests/test_rns_bridge_discovery.py
"""

import ast
import json
import sys
import types
import unittest
from pathlib import Path

# Make the worktree root importable regardless of how this file is launched
# (pytest inserts CWD when run as `python -m pytest`; running the file
# directly would only put tests/ on sys.path).
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


# ── Stubs, installed BEFORE `import app.rns_bridge` ─────────────────────────

def _make_autoconnected_iface(endpoint: str):
    class _Iface:
        autoconnect_hash = "fake_hash"

        def __str__(self) -> str:
            return endpoint

    return _Iface()


def _make_plain_iface(endpoint: str):
    class _Iface:
        def __str__(self) -> str:
            return endpoint

    return _Iface()


def _install_stubs() -> None:
    # Fixed discovery result from the "on-disk announce store" read path.
    # transport_id / network_id arrive as msgpack BYTES — the bridge must
    # hex-encode them.
    infos = [
        {
            "name": "Smoke Hub",
            "type": "tcp",
            "transport_id": b"\x01\x02\xab",
            "network_id": b"\xde\xad\xbe\xef",
            "status": "announced",
            "status_code": 1,
            "last_heard": 1700000000,
            "value": 1234,
            "port": 4242,
        }
    ]

    class Reticulum:
        @staticmethod
        def discovered_interfaces():
            return infos

        @staticmethod
        def should_autoconnect_discovered_interfaces():
            return True

    class Transport:
        # One auto-connected endpoint ("1.2.3.4:4242") and one plain
        # interface that must be filtered out of `autoconnected`.
        interfaces = [
            _make_autoconnected_iface("1.2.3.4:4242"),
            _make_plain_iface("9.9.9.9:4444"),
        ]

    rns_stub = types.ModuleType("RNS")
    rns_stub.Reticulum = Reticulum
    rns_stub.Transport = Transport
    rns_stub.Identity = type("Identity", (), {})
    rns_stub.Destination = type("Destination", (), {"IN": 1, "SINGLE": 0})
    rns_stub.LOG_DEBUG = 0
    rns_stub.LOG_INFO = 1
    rns_stub.LOG_WARNING = 2
    rns_stub.LOG_ERROR = 3
    rns_stub.log = lambda *a, **kw: None  # noqa: ARG005 — silence only

    lxmf_stub = types.ModuleType("LXMF")

    sys.modules["RNS"] = rns_stub
    sys.modules["LXMF"] = lxmf_stub


_install_stubs()

import app.rns_bridge  # noqa: E402  (must follow _install_stubs())


BRIDGE_PATH = ROOT / "app" / "rns_bridge.py"


class DiscoveryJsonTest(unittest.TestCase):
    def setUp(self):
        self._started = app.rns_bridge._state.get("started")
        app.rns_bridge._state["started"] = True

    def tearDown(self):
        if self._started is None:
            app.rns_bridge._state.pop("started", None)
        else:
            app.rns_bridge._state["started"] = self._started

    def test_ast_contract(self):
        """ast.parse contract: discovery_json exists and the module parses."""
        tree = ast.parse(BRIDGE_PATH.read_text(encoding="utf-8"))
        names = [n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]
        self.assertIn("discovery_json", names)

    def test_discovery_json_shape_and_coercion(self):
        raw = app.rns_bridge.discovery_json()
        data = json.loads(raw)
        self.assertIsInstance(data, dict)
        self.assertIn("discovered", data)
        self.assertIn("enabled", data)
        self.assertIn("autoconnected", data)

        # bytes transport_id / network_id are hex-encoded for Swift.
        self.assertEqual(len(data["discovered"]), 1)
        info = data["discovered"][0]
        self.assertEqual(info["transport_id"], "0102ab")
        self.assertEqual(info["network_id"], "deadbeef")
        self.assertEqual(info["name"], "Smoke Hub")
        self.assertEqual(info["port"], 4242)

        # Autoconnect flag surfaces through the stub (True).
        self.assertIs(data["enabled"], True)

        # Only auto-connected interfaces appear, sorted.
        self.assertEqual(data["autoconnected"], ["1.2.3.4:4242"])

    def test_discovery_json_not_started_returns_empty_shape(self):
        app.rns_bridge._state["started"] = False
        data = json.loads(app.rns_bridge.discovery_json())
        self.assertEqual(
            data,
            {"discovered": [], "enabled": False, "autoconnected": []},
        )


if __name__ == "__main__":
    unittest.main()
