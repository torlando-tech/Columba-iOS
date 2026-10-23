import ast
import threading
import time
import types
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"


class FakeRouter:
    def __init__(self, state: int):
        self.outbound_propagation_node = object()
        self.propagation_transfer_state = state
        self.request_state = state
        self.request_result = 0
        self.outbound_propagation_link = None
        self.propagation_transfer_last_result = 0
        self.requests = 0
        self.cancelled = 0
        self.requested = threading.Event()
        self.cancel_entered = threading.Event()
        self.cancel_release: threading.Event | None = None

    def request_messages_from_propagation_node(self, _identity):
        self.requests += 1
        link = self.outbound_propagation_link
        if link is not None and link.status != 2:
            return
        self.propagation_transfer_state = self.request_state
        self.propagation_transfer_last_result = self.request_result
        self.requested.set()

    def cancel_propagation_node_requests(self):
        self.cancelled += 1
        self.cancel_entered.set()
        if self.cancel_release is not None:
            self.cancel_release.wait(timeout=1.0)


class PropagationSyncCancellationTests(unittest.TestCase):
    def load_functions(self, router: FakeRouter):
        tree = ast.parse(BRIDGE.read_text(encoding="utf-8"))
        functions: list[ast.stmt] = [
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
            and node.name in {
                "propagation_sync",
                "cancel_propagation_sync",
                "_cancel_router_propagation_request",
                "_propagation_state_name",
            }
        ]
        router_type = types.SimpleNamespace(
            PR_IDLE=0,
            PR_COMPLETE=5,
            PR_NO_PATH=6,
            PR_TRANSFER_FAILED=7,
            PR_LINK_FAILED=10,
            PR_NO_IDENTITY_RCVD=11,
            PR_NO_ACCESS=12,
            PR_FAILED=13,
            PR_PATH_REQUESTED=1,
            PR_LINK_ESTABLISHING=2,
            PR_LINK_ESTABLISHED=3,
            PR_REQUEST_SENT=4,
            PR_RECEIVING=8,
            PR_RESPONSE_RECEIVED=9,
        )
        namespace = {
            "Any": Any,
            "LXMF": types.SimpleNamespace(LXMRouter=router_type),
            "RNS": types.SimpleNamespace(Link=types.SimpleNamespace(ACTIVE=2, CLOSED=4)),
            "threading": threading,
            "time": time,
            "_lock": threading.Lock(),
            "_propagation_sync_cancellation_lock": threading.Condition(),
            "_active_propagation_sync_cancellation": None,
            "_state": {"started": True, "router": router, "identity": object()},
        }
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(BRIDGE), "exec"), namespace)
        return namespace

    def test_late_cancellation_after_completion_does_not_poison_next_sync(self):
        router = FakeRouter(state=5)
        bridge = self.load_functions(router)

        self.assertTrue(bridge["propagation_sync"]()["ok"])
        self.assertEqual(
            bridge["cancel_propagation_sync"](),
            {"ok": True, "active": False, "router_cancelled": False},
        )
        self.assertTrue(bridge["propagation_sync"]()["ok"])
        self.assertEqual(router.requests, 2)
        self.assertEqual(router.cancelled, 0)

    def test_active_cancellation_only_interrupts_current_sync(self):
        router = FakeRouter(state=0)
        bridge = self.load_functions(router)
        result = {}
        worker = threading.Thread(
            target=lambda: result.update(bridge["propagation_sync"](timeout=2.0))
        )
        worker.start()
        self.assertTrue(router.requested.wait(timeout=1.0))

        self.assertEqual(
            bridge["cancel_propagation_sync"](),
            {"ok": True, "active": True, "router_cancelled": True},
        )
        worker.join(timeout=1.5)

        self.assertFalse(worker.is_alive())
        self.assertEqual(result["state"], "cancelled")
        self.assertEqual(router.cancelled, 1)

        router.request_state = 5
        self.assertTrue(bridge["propagation_sync"]()["ok"])

    def test_next_sync_waits_for_router_cancellation_to_finish(self):
        router = FakeRouter(state=0)
        router.cancel_release = threading.Event()
        bridge = self.load_functions(router)
        first_result = {}
        first = threading.Thread(
            target=lambda: first_result.update(bridge["propagation_sync"](timeout=2.0))
        )
        first.start()
        self.assertTrue(router.requested.wait(timeout=1.0))

        cancellation = threading.Thread(target=bridge["cancel_propagation_sync"])
        cancellation.start()
        self.assertTrue(router.cancel_entered.wait(timeout=1.0))

        next_result = {}
        successor = threading.Thread(
            target=lambda: next_result.update(bridge["propagation_sync"](timeout=2.0))
        )
        successor.start()
        time.sleep(0.1)
        self.assertEqual(router.requests, 1)

        router.request_state = 5
        router.cancel_release.set()
        cancellation.join(timeout=1.0)
        first.join(timeout=1.0)
        successor.join(timeout=1.0)

        self.assertFalse(cancellation.is_alive())
        self.assertFalse(first.is_alive())
        self.assertFalse(successor.is_alive())
        self.assertEqual(first_result["state"], "cancelled")
        self.assertTrue(next_result["ok"])
        self.assertEqual(router.requests, 2)

    def test_timeout_cancels_router_before_releasing_operation_slot(self):
        router = FakeRouter(state=0)
        bridge = self.load_functions(router)

        result = bridge["propagation_sync"](timeout=0.01)

        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "timeout")
        self.assertEqual(router.cancelled, 1)
        self.assertIsNone(bridge["_active_propagation_sync_cancellation"])

    def test_all_pinned_failure_states_are_terminal(self):
        states = {
            6: "no_path",
            7: "transfer_failed",
            10: "link_failed",
            11: "no_identity_received",
            12: "no_access",
            13: "failed",
        }
        for state, expected_name in states.items():
            with self.subTest(state=state):
                router = FakeRouter(state=state)
                bridge = self.load_functions(router)
                started = time.monotonic()
                result = bridge["propagation_sync"](timeout=1.0)
                self.assertLess(time.monotonic() - started, 0.5)
                self.assertFalse(result["ok"])
                self.assertEqual(result["state"], expected_name)

    def link_scenario(self, previous_state: int, initial_status: int, next_status: int | None):
        router = FakeRouter(state=previous_state)
        router.request_state = 5
        router.request_result = 2
        router.propagation_transfer_last_result = 17
        link = types.SimpleNamespace(status=initial_status)
        router.outbound_propagation_link = link
        bridge = self.load_functions(router)
        now = 0.0

        def sleep(seconds):
            nonlocal now
            now += seconds
            if next_status is not None:
                link.status = next_status

        bridge["time"] = types.SimpleNamespace(monotonic=lambda: now, sleep=sleep)
        return router, bridge

    def test_pending_upload_link_does_not_reuse_previous_sync_result(self):
        for previous_state in (5, 10):
            with self.subTest(previous_state=previous_state):
                router, bridge = self.link_scenario(previous_state, 0, 2)

                result = bridge["propagation_sync"](timeout=2.0)

                self.assertEqual(
                    result,
                    {"ok": True, "state": "complete", "received_messages": 2, "reason": "ok"},
                )
                self.assertEqual(router.requests, 1)
                self.assertEqual(router.cancelled, 0)

    def test_already_closed_link_is_discarded_before_a_fresh_request(self):
        router, bridge = self.link_scenario(10, 4, None)

        result = bridge["propagation_sync"](timeout=2.0)

        self.assertTrue(result["ok"])
        self.assertEqual(result["received_messages"], 2)
        self.assertEqual(router.requests, 1)

    def test_pending_link_failure_is_not_previous_success(self):
        router, bridge = self.link_scenario(5, 0, 4)

        result = bridge["propagation_sync"](timeout=2.0)

        self.assertEqual(
            result,
            {"ok": False, "state": "link_failed", "received_messages": 0, "reason": "link_failed"},
        )
        self.assertEqual(router.requests, 0)

    def test_waiting_for_existing_link_uses_sync_timeout(self):
        router, bridge = self.link_scenario(5, 0, None)

        result = bridge["propagation_sync"](timeout=1.0)

        self.assertEqual(result["reason"], "timeout")
        self.assertFalse(result["ok"])
        self.assertEqual(result["received_messages"], 0)
        self.assertEqual(router.cancelled, 1)

    def test_cancellation_while_waiting_does_not_start_download(self):
        router, bridge = self.link_scenario(5, 0, None)
        advance = bridge["time"].sleep

        def cancel(seconds):
            advance(seconds)
            bridge["cancel_propagation_sync"]()

        bridge["time"].sleep = cancel
        result = bridge["propagation_sync"](timeout=2.0)

        self.assertEqual(result["state"], "cancelled")
        self.assertEqual(router.requests, 0)
        self.assertEqual(router.cancelled, 1)

    def test_current_failure_does_not_report_previous_received_count(self):
        router = FakeRouter(state=10)
        router.request_result = 17
        bridge = self.load_functions(router)

        result = bridge["propagation_sync"](timeout=1.0)

        self.assertFalse(result["ok"])
        self.assertEqual(result["state"], "link_failed")
        self.assertEqual(result["received_messages"], 0)


if __name__ == "__main__":
    unittest.main()