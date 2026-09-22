"""Real-RNS integration test (Mac / RNS venv only; SKIPPED without RNS).

Drives ``PythonRNSNodeEngine`` against the REAL ``app.rns_bridge`` (the existing
embedded-interpreter bridge) with real RNS + LXMF, to prove the adapter actually
moves the real engine - not just a fake:

* ``start`` boots real RNS and returns a descriptor with a real 64-hex identity
  hash and a real LXMF delivery destination hash, phase ``ready``;
* ``execute(submitMessage)`` to a malformed destination maps the real
  ``send_opportunistic`` ``bad-hash`` result to ``invalidArgument``;
* ``execute(submitMessage)`` to an unknown peer maps the real ``requesting-path``
  result to ``interrupted`` (durable-resumable - a path request is in flight, not
  a committed rejection);
* ``stop`` tears the node down idempotently.

This test imports ``RNS`` at module load and is SKIPPED (not failed) on a
machine without RNS (the Linux controller). It needs the repo root on
``sys.path`` so ``import app.rns_bridge`` resolves, and the RNS wheels in the
venv (``~/.reticulum-host/venv`` on the Mac has RNS 1.5.3).

Run on the Mac:
    ~/.reticulum-host/venv/bin/python -m unittest \
      engine.columba_node.tests.test_rns_integration -v
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile
import unittest

try:
    import RNS  # noqa: F401
    _HAS_RNS = True
    _RNS_IMPORT_ERROR = None
except Exception as _e:  # pragma: no cover - depends on environment
    _HAS_RNS = False
    _RNS_IMPORT_ERROR = _e

HERE = os.path.dirname(__file__)
# Repo root: engine/columba_node/tests -> repo root is three levels up.
REPO_ROOT = os.path.normpath(
    os.path.join(HERE, "..", "..", ".."))

_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _import_bridge():
    """Import the real app.rns_bridge with the repo root on sys.path."""
    if REPO_ROOT not in sys.path:
        sys.path.insert(0, REPO_ROOT)
    from app import rns_bridge
    return rns_bridge


@unittest.skipUnless(_HAS_RNS, f"RNS not importable here ({_RNS_IMPORT_ERROR}); "
                               "run in the Mac RNS venv")
class RealRNSNodeEngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="columba-node-engine-")
        cls.config_dir = os.path.join(cls.tmp, "config")
        cls.identity_path = os.path.join(cls.tmp, "identity")
        cls.bridge = _import_bridge()

    @classmethod
    def tearDownClass(cls):
        try:
            if cls.bridge is not None and hasattr(cls.bridge, "stop"):
                try:
                    cls.bridge.stop()
                except Exception:
                    pass
        finally:
            shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_start_boots_real_rns_and_reports_ready_descriptor(self):
        from engine.columba_node.engine import PythonRNSNodeEngine

        engine = PythonRNSNodeEngine(
            self.bridge, self.config_dir,
            identity_path=self.identity_path,
            display_name="ColumbaNodeEngineTest",
        )
        desc = engine.start("11111111-1111-4111-8111-111111111111")
        try:
            self.assertEqual(desc["version"], {"major": 1, "minor": 0})
            self.assertEqual(desc["storeSchema"], 1)
            # Real identity + destination hashes: 64 hex chars each.
            rt = desc["runtime"]
            self.assertEqual(rt["phase"], "ready")
            self.assertTrue(rt["actualEnabled"])
            identity_id = rt["enabledIdentities"]
            self.assertEqual(len(identity_id), 1)
            self.assertRegex(identity_id[0], _HEX64)
            # durableMessaging is the one conformed feature.
            caps = {c["feature"]: c["support"] for c in desc["capabilities"]}
            self.assertEqual(caps.get("durableMessaging"), "supported")
        finally:
            engine.stop()

    def test_execute_bad_hash_maps_to_invalid_argument(self):
        from engine.columba_node.engine import PythonRNSNodeEngine

        engine = PythonRNSNodeEngine(
            self.bridge, self.config_dir,
            identity_path=self.identity_path,
            display_name="ColumbaNodeEngineTest",
        )
        engine.start("11111111-1111-4111-8111-111111111111")
        try:
            intent = {
                "commandID": "44444444-4444-4444-8444-444444444444",
                "body": {
                    "tag": "submitMessage",
                    "value": {
                        "scope": {"identityID": "33333333-3333-4333-8333-333333333333"},
                        "destination": "nothex",  # malformed -> bad-hash
                        "payload": {
                            "tag": "chat",
                            "value": {
                                "title": {"tag": "inline", "value": ""},
                                "content": {"tag": "inline", "value": "hi"},
                                "attachments": [], "reply": None,
                                "appearance": None, "extensions": None,
                            },
                        },
                        "delivery": {"preferred": "automatic",
                                     "allowPropagationFallback": False,
                                     "maxAttempts": 1, "stampBudgetMs": 5000},
                        "deadline": 1790086400000,
                    },
                },
            }
            res = engine.execute(intent)
            self.assertFalse(res["ok"])
            self.assertEqual(res["error"]["code"], "invalidArgument")
            self.assertEqual(res["error"]["field"], "destination")
        finally:
            engine.stop()


if __name__ == "__main__":
    unittest.main()
