"""Engine-adapter mapping tests (pure Python, no RNS).

These prove the ``PythonRNSNodeEngine`` maps the contract surface onto the
``rns_bridge`` operations correctly, using a FAKE bridge that exposes the same
three functions (``start`` / ``send_opportunistic`` / ``stop``). Because the
bridge is injected, the mapping is provable on the Linux controller with NO RNS;
the Mac venv (RNS 1.5.3) runs the same tests against the real runtime in a
separate integration test.

Run:
    python3 -m unittest engine.columba_node.tests.test_engine -v
"""

from __future__ import annotations

import unittest

from engine.columba_node.engine import (
    ADAPTER_REVISION,
    PythonRNSNodeEngine,
)


class FakeBridge:
    """Stand-in for ``app.rns_bridge`` exposing the three operations the engine
    uses. Records calls so tests can assert the exact bridge invocation."""

    def __init__(self, send_result=None, started=True):
        self.start_calls = []
        self.send_calls = []
        self.stop_calls = 0
        self.started = started
        self.send_result = send_result or {"ok": True, "reason": "queued",
                                            "message_hash": "deadbeef" * 16}
        # A stand-in for the bridge module's RNS attribute (version probe).
        class _RNS:
            __version__ = "1.5.3-fake"
        self.RNS = _RNS

    def start(self, config_dir, identity_path, display_name, identity_bytes=None):
        self.start_calls.append({
            "config_dir": config_dir,
            "identity_path": identity_path,
            "display_name": display_name,
            "identity_bytes": identity_bytes,
        })
        return {"identity_hash": "aa" * 32, "destination_hash": "bb" * 32}

    def send_opportunistic(self, dest_hash_hex, content, fields_hex="",
                           method="opportunistic", failure_fallback_method=""):
        self.send_calls.append({
            "dest": dest_hash_hex, "content": content,
            "fields_hex": fields_hex, "method": method,
            "fallback": failure_fallback_method,
        })
        return dict(self.send_result)

    def stop(self):
        self.stop_calls += 1


def _submit_message_intent(destination="cc" * 32, content="Hello from Columba",
                           command_id="44444444-4444-4444-8444-444444444444"):
    """A staged submitMessage intent in the exact Swift wire shape."""
    return {
        "commandID": command_id,
        "body": {
            "tag": "submitMessage",
            "value": {
                "scope": {"identityID": "33333333-3333-4333-8333-333333333333"},
                "destination": destination,
                "payload": {
                    "tag": "chat",
                    "value": {
                        "title": {"tag": "inline", "value": ""},
                        "content": {"tag": "inline", "value": content},
                        "attachments": [],
                        "reply": None,
                        "appearance": None,
                        "extensions": None,
                    },
                },
                "delivery": {
                    "preferred": "automatic",
                    "allowPropagationFallback": False,
                    "maxAttempts": 3,
                    "stampBudgetMs": 5000,
                },
                "deadline": 1790086400000,
            },
        },
    }


class DescriptorTests(unittest.TestCase):
    def _started(self, bridge):
        eng = PythonRNSNodeEngine(bridge, "/tmp/cfg")
        return eng, eng.start("11111111-1111-4111-8111-111111111111")

    def test_descriptor_shape_and_capability_set(self):
        bridge = FakeBridge()
        eng, desc = self._started(bridge)
        # Descriptor fields match the Swift wire shape.
        self.assertEqual(desc["version"], {"major": 1, "minor": 0})
        self.assertEqual(desc["storeEpoch"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(desc["storeSchema"], 1)
        self.assertEqual(desc["backend"]["name"], "python-rns")
        self.assertEqual(desc["backend"]["adapterRevision"], ADAPTER_REVISION)
        self.assertEqual(desc["backend"]["revision"], "1.5.3-fake")
        # Only durableMessaging is supported; the rest fail closed to unsupported.
        caps = {c["feature"]: c for c in desc["capabilities"]}
        self.assertEqual(caps["durableMessaging"]["support"], "supported")
        self.assertEqual(caps["durableMessaging"]["availability"], "available")
        for f in ("attachments", "replies", "reactions",
                  "reactionRemoval", "extensionFields"):
            self.assertEqual(caps[f]["support"], "unsupported")
            self.assertEqual(caps[f]["availability"], "disabled")
            self.assertIn("reason", caps[f])

    def test_runtime_snapshot_ready_when_started(self):
        bridge = FakeBridge()
        eng, desc = self._started(bridge)
        rt = desc["runtime"]
        self.assertEqual(rt["phase"], "ready")
        self.assertTrue(rt["actualEnabled"])
        self.assertEqual(rt["connectivity"], "interfacesAvailable")
        self.assertEqual(rt["enabledIdentities"], ["aa" * 32])

    def test_runtime_snapshot_stopped_before_start(self):
        eng = PythonRNSNodeEngine(FakeBridge(), "/tmp/cfg")
        rt = eng.runtime_snapshot()
        self.assertEqual(rt["phase"], "stopped")
        self.assertFalse(rt["actualEnabled"])
        self.assertEqual(rt["connectivity"], "noInterfaces")

    def test_start_delegates_to_bridge(self):
        bridge = FakeBridge()
        eng = PythonRNSNodeEngine(bridge, "/tmp/cfg",
                                  identity_path="/tmp/id",
                                  display_name="Columba",
                                  identity_bytes=b"\x00" * 64)
        eng.start("11111111-1111-4111-8111-111111111111")
        self.assertEqual(bridge.start_calls[0]["config_dir"], "/tmp/cfg")
        self.assertEqual(bridge.start_calls[0]["identity_path"], "/tmp/id")
        self.assertEqual(bridge.start_calls[0]["display_name"], "Columba")
        self.assertEqual(bridge.start_calls[0]["identity_bytes"], b"\x00" * 64)

    def test_stop_is_idempotent_and_calls_bridge(self):
        bridge = FakeBridge()
        eng = PythonRNSNodeEngine(bridge, "/tmp/cfg")
        eng.start("11111111-1111-4111-8111-111111111111")
        eng.stop()
        eng.stop()  # second stop is a no-op
        self.assertEqual(bridge.stop_calls, 1)
        # After stop, snapshot reports stopped.
        self.assertEqual(eng.runtime_snapshot()["phase"], "stopped")


class CapabilityGateTests(unittest.TestCase):
    def _started_engine(self, bridge):
        eng = PythonRNSNodeEngine(bridge, "/tmp/cfg")
        eng.start("11111111-1111-4111-8111-111111111111")
        return eng

    def test_can_execute_allows_submit_message(self):
        eng = self._started_engine(FakeBridge())
        self.assertIsNone(eng.can_execute(_submit_message_intent()))

    def test_can_execute_rejects_before_start(self):
        eng = PythonRNSNodeEngine(FakeBridge(), "/tmp/cfg")
        err = eng.can_execute(_submit_message_intent())
        self.assertEqual(err["code"], "unavailable")

    def test_can_execute_rejects_unknown_command_class(self):
        eng = self._started_engine(FakeBridge())
        intent = {"commandID": "x", "body": {"tag": "configureSomething", "value": {}}}
        err = eng.can_execute(intent)
        self.assertEqual(err["code"], "featureDisabled")


class ExecuteMappingTests(unittest.TestCase):
    def _started(self, send_result):
        bridge = FakeBridge(send_result=send_result)
        eng = PythonRNSNodeEngine(bridge, "/tmp/cfg")
        eng.start("11111111-1111-4111-8111-111111111111")
        return bridge, eng

    def test_queued_produces_ok_with_operation_change(self):
        bridge, eng = self._started({"ok": True, "reason": "queued",
                                     "message_hash": "deadbeef" * 16})
        intent = _submit_message_intent(command_id="44444444-4444-4444-8444-444444444444")
        res = eng.execute(intent)
        self.assertTrue(res["ok"])
        change = res["change"]
        self.assertEqual(change["entity"], "operation")
        self.assertEqual(change["key"], "44444444-4444-4444-8444-444444444444")
        self.assertEqual(change["identityID"], "aa" * 32)
        self.assertEqual(change["removed"], False)
        self.assertEqual(change["detail"]["messageHash"], "deadbeef" * 16)
        # The bridge got the content and destination mapped from the intent.
        self.assertEqual(bridge.send_calls[0]["content"], "Hello from Columba")
        self.assertEqual(bridge.send_calls[0]["dest"], "cc" * 32)
        self.assertEqual(bridge.send_calls[0]["method"], "opportunistic")
        self.assertEqual(bridge.send_calls[0]["fallback"], "")

    def test_requesting_path_is_interrupted_not_rejected(self):
        _, eng = self._started({"ok": False, "reason": "requesting-path"})
        res = eng.execute(_submit_message_intent())
        # Contract: durable-resumable, no path yet -> interrupted, NOT a
        # committed rejection (the ledger stays accepted, RNS keeps the path
        # request going).
        self.assertFalse(res["ok"])
        self.assertTrue(res["interrupted"])
        self.assertNotIn("error", res)

    def test_not_started_is_unavailable(self):
        _, eng = self._started({"ok": False, "reason": "not-started"})
        res = eng.execute(_submit_message_intent())
        err = res["error"]
        self.assertEqual(err["code"], "unavailable")

    def test_bad_hash_is_invalid_argument(self):
        _, eng = self._started({"ok": False, "reason": "bad-hash"})
        res = eng.execute(_submit_message_intent())
        err = res["error"]
        self.assertEqual(err["code"], "invalidArgument")
        self.assertEqual(err["field"], "destination")

    def test_no_propagation_node_is_transport_unavailable_retryable(self):
        _, eng = self._started({"ok": False, "reason": "no-propagation-node"})
        res = eng.execute(_submit_message_intent())
        err = res["error"]
        self.assertEqual(err["code"], "transportUnavailable")
        self.assertEqual(err["retry"], "afterStateChange")

    def test_unknown_reason_is_dependency_failed(self):
        _, eng = self._started({"ok": False, "reason": "mystery-failure"})
        res = eng.execute(_submit_message_intent())
        err = res["error"]
        self.assertEqual(err["code"], "dependencyFailed")

    def test_non_inline_content_rejected(self):
        _, eng = self._started({"ok": True, "reason": "queued",
                                "message_hash": "ff" * 32})
        intent = _submit_message_intent()
        # Swap in a non-inline (attachment) content -> unsupported this slice.
        intent["body"]["value"]["payload"]["value"]["content"] = {
            "tag": "attachment", "value": {"blobID": "b1"}}
        res = eng.execute(intent)
        self.assertFalse(res["ok"])
        err = res["error"]
        self.assertEqual(err["code"], "unsupported")
        self.assertEqual(err["field"], "payload.content")

    def test_delivery_mapping_prefers_direct_and_propagated_fallback(self):
        bridge, eng = self._started({"ok": True, "reason": "queued",
                                     "message_hash": "00" * 32})
        intent = _submit_message_intent()
        intent["body"]["value"]["delivery"] = {
            "preferred": "direct",
            "allowPropagationFallback": True,
            "maxAttempts": 2,
            "stampBudgetMs": 1000,
        }
        eng.execute(intent)
        self.assertEqual(bridge.send_calls[0]["method"], "direct")
        self.assertEqual(bridge.send_calls[0]["fallback"], "propagated")


if __name__ == "__main__":
    unittest.main()
