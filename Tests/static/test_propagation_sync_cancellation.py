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
        self.propagation_transfer_last_result = 0
        self.requests = 0
        self.cancelled = 0
        self.requested = threading.Event()
        self.cancel_entered = threading.Event()
        self.cancel_release: threading.Event | None = None

    def request_messages_from_propagation_node(self, _identity):
        self.requests += 1
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
                "_propagation_state_name",
            }
        ]
        router_type = types.SimpleNamespace(
            PR_COMPLETE=5,
            PR_NO_PATH=6,
            PR_TRANSFER_FAILED=7,
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

        router.propagation_transfer_state = 5
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

        router.propagation_transfer_state = 5
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

    def test_swift_cancellation_is_scoped_to_the_originating_operation(self):
        manager = (
            ROOT / "Sources" / "ColumbaApp" / "Services" / "PropagationNodeManager.swift"
        ).read_text(encoding="utf-8")
        app = (
            ROOT / "Sources" / "ColumbaApp" / "App" / "ColumbaApp.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("activeSyncOperationID == operationID", manager)
        self.assertIn("cancelActiveSync(operationID: UUID)", manager)
        self.assertIn("cancelActiveSync(operationID: syncOperationID)", app)


if __name__ == "__main__":
    unittest.main()