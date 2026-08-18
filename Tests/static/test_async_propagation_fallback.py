import ast
import copy
import inspect
import threading
import time
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
    PACKET = 0x04

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
        self.packed = None
        self.propagation_packed = None
        self.representation = None
        self.delivery_callback = None
        self.failed_callback = None
        self.pack_entered = None
        self.pack_release = None

    def pack(self):
        self.packed = b"packed-payload"
        self.method = self.desired_method
        self.representation = self.PACKET
        self.propagation_packed = (
            b"propagation-payload"
            if self.desired_method == self.PROPAGATED
            else None
        )
        if self.pack_entered is not None:
            self.pack_entered.set()
            if self.pack_release is not None:
                self.pack_release.wait(timeout=1.0)

    def register_delivery_callback(self, callback):
        self.delivery_callback = callback

    def register_failed_callback(self, callback):
        self.failed_callback = callback


class FakeRouter:
    def __init__(self, *, propagation_node=True, reject_propagated=False):
        self.outbound_propagation_node = object() if propagation_node else None
        self.reject_propagated = reject_propagated
        self.handled = []
        self._handled_condition = threading.Condition()

    def handle_outbound(self, message):
        if message.packed is None:
            message.pack()
        with self._handled_condition:
            self.handled.append(message)
            self._handled_condition.notify_all()
        if message.method == FakeMessage.PROPAGATED and self.reject_propagated:
            raise OSError("propagation enqueue rejected")

    def wait_for_handled_count(self, count: int, timeout: float = 1.0) -> bool:
        deadline = time.monotonic() + timeout
        with self._handled_condition:
            while len(self.handled) < count:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self._handled_condition.wait(remaining)
            return True


class LockedCallbackRouter(FakeRouter):
    def __init__(self):
        super().__init__()
        self.outbound_processing_lock = threading.Lock()

    def handle_outbound(self, message):
        if not self.handled:
            return super().handle_outbound(message)
        if not self.outbound_processing_lock.acquire(timeout=0.25):
            raise TimeoutError("re-entered outbound router while callback lock held")
        try:
            return super().handle_outbound(message)
        finally:
            self.outbound_processing_lock.release()


class AdmissionBlockingRouter(FakeRouter):
    def __init__(self):
        super().__init__()
        self.second_handle_entered = threading.Event()
        self.second_handle_release = threading.Event()

    def handle_outbound(self, message):
        if self.handled:
            self.second_handle_entered.set()
            self.second_handle_release.wait(timeout=1.0)
        return super().handle_outbound(message)


class BlockingLifecycleEvents(list):
    def __init__(self):
        super().__init__()
        self.sent_put_entered = threading.Event()
        self.sent_put_release = threading.Event()

    def append(self, item):
        kind, payload = item
        if kind == "delivery" and payload.get("state") == "sent":
            self.sent_put_entered.set()
            self.sent_put_release.wait(timeout=1.0)
        super().append(item)


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
        bridge_lock = threading.Lock()
        runtime_state = {"started": True, "router": router, "destination": object()}
        namespace = {
            "Any": Any,
            "LXMF": types.SimpleNamespace(LXMessage=FakeMessage),
            "RNS": types.SimpleNamespace(
                Identity=FakeIdentity,
                Destination=FakeDestination,
                Transport=types.SimpleNamespace(request_path=lambda _hash: None),
            ),
            "_lock": bridge_lock,
            "copy": copy,
            "threading": threading,
            "_runtime_teardown_requested": threading.Event(),
            "_state": runtime_state,
            "_put": lambda kind, **payload: events.append((kind, payload)),
        }
        exec(
            compile(ast.Module(body=[function], type_ignores=[]), str(BRIDGE), "exec"),
            namespace,
        )
        self.loaded_bridge_lock = bridge_lock
        self.loaded_runtime_state = runtime_state
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

    def wait_for_delivery_events(self, events, count: int, timeout: float = 1.0) -> bool:
        deadline = time.monotonic() + timeout
        while len(self.delivery_events(events)) < count:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.001)
        return True

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

        self.assertTrue(router.wait_for_handled_count(2))
        self.assertEqual(2, len(router.handled))
        retry = router.handled[1]
        self.assertIs(primary, retry)
        self.assertEqual(
            original,
            (retry.hash.hex(), retry.timestamp, retry.content, retry.title, retry.fields),
        )
        self.assertEqual(FakeMessage.PROPAGATED, retry.desired_method)
        self.assertEqual(FakeMessage.PROPAGATED, retry.method)
        self.assertEqual(b"propagation-payload", retry.propagation_packed)
        self.assertEqual(FakeMessage.PACKET, retry.representation)
        self.assertEqual(FakeMessage.OUTBOUND, retry.state)
        self.assertEqual(0, retry.delivery_attempts)
        self.assertEqual(0.0, retry.progress)
        self.assertEqual(
            ["retrying_propagated"],
            [event["state"] for event in self.delivery_events(events)],
        )

        primary.failed_callback(primary)
        self.assertEqual(2, len(router.handled), "duplicate failure requeued twice")
        self.assertEqual(2, len(self.delivery_events(events)))
        self.assertEqual("failed", self.delivery_events(events)[1]["state"])
        self.assertEqual("propagated-failed", self.delivery_events(events)[1]["reason"])

    def test_explicit_propagated_send_without_node_is_rejected_before_queue(self):
        router = FakeRouter(propagation_node=False)
        events = []
        send = self.load_send(router, events)

        result = send(
            dest_hash_hex="01" * 16,
            content="hello",
            fields_hex="",
            method="propagated",
            failure_fallback_method="",
        )

        self.assertFalse(result["ok"])
        self.assertEqual("no-propagation-node", result["reason"])
        self.assertEqual([], router.handled)
        self.assertEqual([], self.delivery_events(events))

    def test_fallback_admission_emits_retrying_before_relay_acceptance(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events)

        message.failed_callback(message)

        self.assertTrue(router.wait_for_handled_count(2))
        self.assertTrue(self.wait_for_delivery_events(events, 1))
        self.assertEqual("retrying_propagated", self.delivery_events(events)[0]["state"])
        self.assertEqual("propagated", self.delivery_events(events)[0]["method"])

        message.state = FakeMessage.SENT
        message.delivery_callback(message)
        self.assertEqual(
            ["retrying_propagated", "sent"],
            [event["state"] for event in self.delivery_events(events)],
        )

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

    def test_propagation_acceptance_does_not_suppress_recipient_proof(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events, method="propagated", fallback="")

        message.state = FakeMessage.SENT
        message.delivery_callback(message)
        message.state = FakeMessage.DELIVERED
        message.delivery_callback(message)

        self.assertEqual(
            ["sent", "delivered"],
            [event["state"] for event in self.delivery_events(events)],
        )

    def test_recipient_proof_upgrades_prior_failure(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events, fallback="")

        message.failed_callback(message)
        message.state = FakeMessage.DELIVERED
        message.delivery_callback(message)

        self.assertEqual(
            ["failed", "delivered"],
            [event["state"] for event in self.delivery_events(events)],
        )

    def test_concurrent_lifecycle_events_cannot_queue_delivered_before_sent(self):
        router = FakeRouter()
        events = BlockingLifecycleEvents()
        message = self.queue(router, events, method="propagated", fallback="")

        message.state = FakeMessage.SENT
        sent_thread = threading.Thread(target=message.delivery_callback, args=(message,))
        sent_thread.start()
        self.assertTrue(events.sent_put_entered.wait(timeout=1.0))

        message.state = FakeMessage.DELIVERED
        delivered_thread = threading.Thread(target=message.delivery_callback, args=(message,))
        delivered_thread.start()
        events.sent_put_release.set()
        sent_thread.join(timeout=1.0)
        delivered_thread.join(timeout=1.0)

        self.assertEqual(
            ["sent", "delivered"],
            [event["state"] for event in self.delivery_events(events)],
        )

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

    def test_missing_propagation_node_preserves_actual_primary_method(self):
        router = FakeRouter(propagation_node=False)
        events = []
        message = self.queue(router, events, method="direct")

        message.failed_callback(message)

        self.assertEqual(1, len(router.handled))
        delivery = self.delivery_events(events)
        self.assertEqual("no-propagation-node", delivery[0]["reason"])
        self.assertEqual("direct", delivery[0]["method"])

    def test_propagated_enqueue_failure_is_terminal_and_does_not_loop(self):
        router = FakeRouter(reject_propagated=True)
        events = []
        message = self.queue(router, events)

        message.failed_callback(message)

        self.assertTrue(router.wait_for_handled_count(2))
        self.assertTrue(self.wait_for_delivery_events(events, 2))
        self.assertEqual(2, len(router.handled))
        self.assertEqual(2, len(self.delivery_events(events)))
        self.assertEqual("propagated-enqueue-failed", self.delivery_events(events)[1]["reason"])
        message.failed_callback(message)
        self.assertEqual(2, len(router.handled))
        self.assertEqual(2, len(self.delivery_events(events)))

    def test_failure_callback_returns_before_locked_router_requeue(self):
        router = LockedCallbackRouter()
        events = []
        message = self.queue(router, events)

        router.outbound_processing_lock.acquire()
        try:
            started = time.monotonic()
            message.failed_callback(message)
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 0.1)
        finally:
            router.outbound_processing_lock.release()

        self.assertTrue(router.wait_for_handled_count(2))
        self.assertEqual(
            ["retrying_propagated"],
            [event["state"] for event in self.delivery_events(events)],
        )

    def test_recipient_proof_cancels_deferred_fallback_before_requeue(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events)

        self.loaded_bridge_lock.acquire()
        try:
            message.failed_callback(message)
            message.state = FakeMessage.DELIVERED
            message.delivery_callback(message)
        finally:
            self.loaded_bridge_lock.release()

        self.assertFalse(router.wait_for_handled_count(2, timeout=0.4))
        self.assertEqual(
            ["delivered"],
            [event["state"] for event in self.delivery_events(events)],
        )

    def test_proof_during_repack_does_not_mutate_primary_or_requeue(self):
        router = FakeRouter()
        events = []
        message = self.queue(router, events)
        message.pack_entered = threading.Event()
        message.pack_release = threading.Event()

        message.failed_callback(message)
        self.assertTrue(message.pack_entered.wait(timeout=1.0))
        message.state = FakeMessage.DELIVERED
        message.delivery_callback(message)
        message.pack_release.set()

        self.assertFalse(router.wait_for_handled_count(2, timeout=0.4))
        delivery = self.delivery_events(events)
        self.assertEqual(["delivered"], [event["state"] for event in delivery])
        self.assertEqual("opportunistic", delivery[0]["method"])
        self.assertEqual(FakeMessage.OPPORTUNISTIC, message.desired_method)
        self.assertEqual(FakeMessage.OPPORTUNISTIC, message.method)
        self.assertIsNone(message.propagation_packed)

    def test_final_enqueue_admission_is_atomic_against_recipient_proof(self):
        router = AdmissionBlockingRouter()
        events = []
        message = self.queue(router, events)

        message.failed_callback(message)
        self.assertTrue(router.second_handle_entered.wait(timeout=1.0))

        message.state = FakeMessage.DELIVERED
        proof_done = threading.Event()
        proof_thread = threading.Thread(
            target=lambda: (message.delivery_callback(message), proof_done.set())
        )
        proof_thread.start()
        self.assertFalse(proof_done.wait(timeout=0.1))

        router.second_handle_release.set()
        proof_thread.join(timeout=1.0)
        self.assertTrue(proof_done.is_set())
        self.assertTrue(router.wait_for_handled_count(2))
        self.assertEqual(
            ["retrying_propagated", "delivered"],
            [event["state"] for event in self.delivery_events(events)],
        )

    def test_runtime_replacement_prevents_requeue_on_superseded_router(self):
        router = LockedCallbackRouter()
        events = []
        message = self.queue(router, events)

        self.loaded_bridge_lock.acquire()
        router.outbound_processing_lock.acquire()
        try:
            message.failed_callback(message)
            self.loaded_runtime_state["router"] = FakeRouter()
        finally:
            self.loaded_bridge_lock.release()
            router.outbound_processing_lock.release()

        self.assertFalse(router.wait_for_handled_count(2, timeout=0.4))
        self.assertTrue(self.wait_for_delivery_events(events, 1))
        self.assertEqual("failed", self.delivery_events(events)[0]["state"])
        self.assertEqual(
            "propagated-enqueue-failed",
            self.delivery_events(events)[0]["reason"],
        )

    def test_delivered_fallback_carries_effective_propagated_method_across_swift_seam(self):
        router = FakeRouter()
        events = []
        primary = self.queue(router, events)

        primary.failed_callback(primary)
        self.assertTrue(router.wait_for_handled_count(2))
        retry = router.handled[1]
        retry.state = FakeMessage.DELIVERED
        retry.delivery_callback(retry)

        delivered = self.delivery_events(events)
        self.assertEqual(2, len(delivered))
        self.assertEqual("retrying_propagated", delivered[0]["state"])
        self.assertEqual("delivered", delivered[1]["state"])
        self.assertEqual("propagated", delivered[1]["method"])

        python_bridge = (ROOT / "Sources/PythonBridge/PythonBridge.swift").read_text()
        rns_backend = (ROOT / "Sources/RNSAPI/Protocols/RnsBackend.swift").read_text()
        python_backend = (ROOT / "Sources/RNSBackendPy/PythonRNSBackend.swift").read_text()
        app_services = (ROOT / "Sources/ColumbaApp/Services/AppServices.swift").read_text()
        messaging_view = (ROOT / "Sources/ColumbaApp/Views/Messaging/MessagingView.swift").read_text()
        messaging_view_model = (
            ROOT / "Sources/ColumbaApp/ViewModels/MessagingViewModel.swift"
        ).read_text()
        message_repository = (
            ROOT / "Sources/ColumbaApp/Services/MessageRepository.swift"
        ).read_text()
        ci_workflow = (ROOT / ".github/workflows/tests.yml").read_text()
        for source in (python_bridge, rns_backend, python_backend):
            self.assertIn("method:", source)
        self.assertIn("method: acceptedMethod", app_services)
        self.assertIn('"deliveryMethod": acceptedMethod?.rawValue ?? ""', app_services)
        self.assertIn("viewModel?.currentMessage(for:", messaging_view)
        self.assertIn("recordCanonicalAlias", messaging_view_model)
        self.assertIn("PendingDeliveryProof", messaging_view_model)
        self.assertIn("method: proof.method", messaging_view_model)
        self.assertIn("outboundSendOperation", messaging_view_model)
        self.assertIn("if !proofPersisted", messaging_view_model)
        self.assertNotIn("if wasAliased && !proofPersisted", messaging_view_model)
        self.assertNotIn("(proof == .delivered) ? .delivered : .failed", messaging_view_model)
        self.assertIn("monotonicDeliveryState", message_repository)
        self.assertIn(") async throws -> Bool", message_repository)
        self.assertIn("let rowUpdated = try await repository.updateMessageState", messaging_view_model)
        self.assertIn("if rowUpdated, pendingDeliveryProofs[hashHex] == proof", messaging_view_model)
        self.assertIn("Tests.static.test_async_propagation_fallback", ci_workflow)

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
