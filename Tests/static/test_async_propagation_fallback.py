import ast
import inspect
import threading
import types
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"


class FakeHash:
    def __init__(self, value: str = "ab" * 32):
        self.value = value

    def hex(self) -> str:
        return self.value


class FakeMessage:
    GENERATING = 0
    OUTBOUND = 1
    SENDING = 2
    SENT = 4
    DELIVERED = 8
    FAILED = 16
    OPPORTUNISTIC = 0x01
    DIRECT = 0x02
    PROPAGATED = 0x03

    def __init__(
        self,
        destination,
        source,
        content,
        title="",
        fields=None,
        desired_method=None,
    ):
        self.destination = destination
        self.source = source
        self.content = content
        self.title = title
        self.fields = fields
        self.desired_method = desired_method
        self.method = desired_method
        self.hash = FakeHash()
        self.timestamp = 1_234.5
        self.state = self.GENERATING
        self.delivery_attempts = 4
        self.progress = 0.75
        self.delivery_callback = None
        self.failed_callback = None

    def register_delivery_callback(self, callback):
        self.delivery_callback = callback

    def register_failed_callback(self, callback):
        self.failed_callback = callback


class FakeRouter:
    def __init__(self, *, propagation_node=True, reject_propagated=False):
        self.outbound_propagation_node = object() if propagation_node else None
        self.reject_propagated = reject_propagated
        self.handled = []

    def handle_outbound(self, message):
        self.handled.append(message)
        if message.method == FakeMessage.PROPAGATED and self.reject_propagated:
            raise OSError("propagation enqueue rejected")


class FakeIdentity:
    @staticmethod
    def recall(_hash):
        return object()


class FakeDestination:
    OUT = 1
    SINGLE = 2

    def __init__(self, *args):
        self.args = args


class AsyncPropagationFallbackTests(unittest.TestCase):
    def load_send(self, router, events):
        tree = ast.parse(BRIDGE.read_text())
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "send_opportunistic"
        )
        namespace = {
            "Any": Any,
            "LXMF": types.SimpleNamespace(LXMessage=FakeMessage),
            "RNS": types.SimpleNamespace(
                Identity=FakeIdentity,
                Destination=FakeDestination,
                Transport=types.SimpleNamespace(request_path=lambda _hash: None),
            ),
            "_lock": threading.Lock(),
            "_state": {"started": True, "router": router, "destination": object()},
            "_put": lambda kind, **payload: events.append((kind, payload)),
        }
        exec(
            compile(ast.Module(body=[function], type_ignores=[]), str(BRIDGE), "exec"),
            namespace,
        )
        return namespace["send_opportunistic"]

    def queue(self, router, events, *, fallback="propagated", method="opportunistic"):
        send = self.load_send(router, events)
        kwargs = {
            "dest_hash_hex": "01" * 16,
            "content": "hello",
            "fields_hex": "",
            "method": method,
        }
        if "failure_fallback_method" in inspect.signature(send).parameters:
            kwargs["failure_fallback_method"] = fallback
        result = send(**kwargs)
        self.assertTrue(result["ok"], result)
        self.assertEqual(1, len(router.handled))
        return router.handled[0]

    def delivery_events(self, events):
        return [payload for kind, payload in events if kind == "delivery"]

    def test_async_failure_requeues_same_message_once_as_propagated(self):
        router = FakeRouter()
        events = []
        primary = self.queue(router, events)
        original = (
            primary.hash.hex(),
            primary.timestamp,
            primary.content,
            primary.title,
            primary.fields,
        )

        primary.failed_callback(primary)

        self.assertEqual(2, len(router.handled))
        retry = router.handled[1]
        self.assertIs(primary, retry)
        self.assertEqual(
            original,
            (retry.hash.hex(), retry.timestamp, retry.content, retry.title, retry.fields),
        )
        self.assertEqual(FakeMessage.PROPAGATED, retry.desired_method)
        self.assertEqual(FakeMessage.PROPAGATED, retry.method)
        self.assertEqual(FakeMessage.OUTBOUND, retry.state)
        self.assertEqual(0, retry.delivery_attempts)
        self.assertEqual(0.0, retry.progress)
        self.assertEqual([], self.delivery_events(events))

        primary.failed_callback(primary)
        self.assertEqual(2, len(router.handled), "duplicate failure requeued twice")
        self.assertEqual(1, len(self.delivery_events(events)))
        self.assertEqual("failed", self.delivery_events(events)[0]["state"])
        self.assertEqual("propagated-failed", self.delivery_events(events)[0]["reason"])

    def test_propagation_acceptance_is_sent_not_delivered(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events, method="propagated", fallback="")
        message.state = FakeMessage.SENT

        message.delivery_callback(message)

        self.assertEqual("sent", self.delivery_events(events)[0]["state"])

    def test_recipient_proof_remains_delivered(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events, fallback="")
        message.state = FakeMessage.DELIVERED

        message.delivery_callback(message)

        self.assertEqual("delivered", self.delivery_events(events)[0]["state"])

    def test_disabled_fallback_emits_final_failure_without_requeue(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events, fallback="")

        message.failed_callback(message)

        self.assertEqual(1, len(router.handled))
        self.assertEqual("failed", self.delivery_events(events)[0]["state"])
        self.assertEqual("primary-failed", self.delivery_events(events)[0]["reason"])

    def test_missing_propagation_node_emits_specific_terminal_failure(self):
        router = FakeRouter(propagation_node=False)
        events = []
        message = self.queue(router, events)

        message.failed_callback(message)

        self.assertEqual(1, len(router.handled))
        self.assertEqual("no-propagation-node", self.delivery_events(events)[0]["reason"])

    def test_propagated_enqueue_failure_is_terminal_and_does_not_loop(self):
        router = FakeRouter(reject_propagated=True)
        events = []
        message = self.queue(router, events)

        message.failed_callback(message)

        self.assertEqual(2, len(router.handled))
        self.assertEqual(1, len(self.delivery_events(events)))
        self.assertEqual("propagated-enqueue-failed", self.delivery_events(events)[0]["reason"])
        message.failed_callback(message)
        self.assertEqual(2, len(router.handled))
        self.assertEqual(1, len(self.delivery_events(events)))

    def test_retry_policy_crosses_the_shipping_swift_python_seam(self):
        rns_lxmf = (ROOT / "Sources/RNSAPI/Protocols/RnsLxmf.swift").read_text()
        backend = (ROOT / "Sources/RNSBackendPy/PythonRNSBackend.swift").read_text()
        bridge = (ROOT / "Sources/PythonBridge/PythonBridge.swift").read_text()
        messaging = (ROOT / "Sources/ColumbaApp/ViewModels/MessagingViewModel.swift").read_text()

        self.assertIn("failureFallbackMethod", rns_lxmf)
        self.assertIn("failureFallbackMethod", backend)
        self.assertIn("failureFallbackMethod", bridge)
        self.assertIn("failureFallbackMethod: retryViaRelay ? .propagated : nil", messaging)

    def test_sent_delivered_failed_states_are_mapped_explicitly(self):
        app_services = (ROOT / "Sources/ColumbaApp/Services/AppServices.swift").read_text()
        messaging = (ROOT / "Sources/ColumbaApp/ViewModels/MessagingViewModel.swift").read_text()

        for state in ('case "sent"', 'case "delivered"', 'case "failed"'):
            self.assertIn(state, app_services)
            self.assertIn(state, messaging)
        self.assertNotIn(
            '(state == "delivered") ? .delivered : .failed',
            messaging,
        )


if __name__ == "__main__":
    unittest.main()
