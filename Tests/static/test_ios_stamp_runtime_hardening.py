#!/usr/bin/env python3
"""Portable regressions for immutable iOS payloads and native stamp lifecycle."""

from __future__ import annotations

import ctypes
import hashlib
import importlib.util
from pathlib import Path
import re
import sys
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
FETCH = ROOT / "support" / "fetch-wheels.sh"
BRIDGE = ROOT / "app" / "rns_bridge.py"
STAMP = ROOT / "Sources" / "SwiftBLEBridge" / "StampGenerator.swift"
RNS_SHA = "5b3a6ee4f25e2925cf84d4a2b108e6a708fbd395"
LXMF_SHA = "8912186e48b482a76bf04e2ac4b6c8940991aecc"


def load_bridge(lx_stamper: object):
    rns = types.ModuleType("RNS")
    rns.LOG_DEBUG = 0
    rns.LOG_WARNING = 1
    rns.LOG_INFO = 2
    rns.LOG_VERBOSE = 3
    rns.log = mock.Mock()
    rns.Transport = types.SimpleNamespace(
        destinations=[], interfaces=[], path_table={}, destination_table={},
        announce_handlers=[], identities={}, deregister_announce_handler=mock.Mock(),
    )
    rns.Reticulum = type("Reticulum", (), {})

    lxmf = types.ModuleType("LXMF")
    lxmf.LXStamper = lx_stamper

    name = f"rns_bridge_stamp_test_{id(lx_stamper)}"
    spec = importlib.util.spec_from_file_location(name, BRIDGE)
    module = importlib.util.module_from_spec(spec)
    old_stdout = sys.stdout
    with mock.patch.dict(sys.modules, {"RNS": rns, "LXMF": lxmf}):
        assert spec.loader is not None
        spec.loader.exec_module(module)
    sys.stdout = old_stdout
    return module


class DependencyPayloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = FETCH.read_text(encoding="utf-8")

    def test_default_rns_and_lxmf_refs_are_exact_immutable_commits(self) -> None:
        self.assertIn(f'RETICULUM_REF="${{RETICULUM_REF:-{RNS_SHA}}}"', self.source)
        self.assertIn(f'LXMF_REF="${{LXMF_REF:-{LXMF_SHA}}}"', self.source)
        self.assertIn("Reticulum.git@${RETICULUM_REF}", self.source)
        self.assertIn("LXMF.git@${LXMF_REF}", self.source)
        self.assertNotRegex(self.source, r"RETICULUM_BRANCH|LXMF_BRANCH")
        for ref in (RNS_SHA, LXMF_SHA):
            self.assertRegex(ref, r"^[0-9a-f]{40}$")

    def test_local_dependency_overrides_remain_explicit(self) -> None:
        self.assertIn("${RETICULUM_LOCAL:-}", self.source)
        self.assertIn("${LXMF_LOCAL:-}", self.source)
        self.assertNotIn("../Reticulum", self.source)
        self.assertNotIn("../LXMF", self.source)

    def test_pure_packages_are_installed_once_then_copied_to_both_platforms(self) -> None:
        calls = re.findall(r"^\s*install_pure_python\b", self.source, re.MULTILINE)
        # One function definition plus exactly one invocation.
        self.assertEqual(2, len(calls))
        self.assertIn('PURE_DIR="', self.source)
        self.assertIn('install_pure_python "$PURE_DIR"', self.source)
        self.assertIn('copy_pure_python "$PURE_DIR" "$SIM_DIR"', self.source)
        self.assertIn('copy_pure_python "$PURE_DIR" "$DEV_DIR"', self.source)
        self.assertEqual(2, len(re.findall(r"^install_binary_wheel ", self.source, re.MULTILINE)))

    def test_dependency_payload_and_version_metadata_are_validated(self) -> None:
        for payload in (
            "RNS/__init__.py", "LXMF/__init__.py",
            "serial/__init__.py", "ble_reticulum/BLEInterface.py",
        ):
            self.assertIn(payload, self.source)
        for name in ("rns", "lxmf", "pyserial", "ble-reticulum"):
            self.assertIn(f'"{name}"', self.source)
        self.assertIn("direct_url.json", self.source)
        self.assertIn("vcs_info", self.source)
        self.assertIn("commit_id", self.source)
        self.assertIn('in {"unknown", "0.0.0"}', self.source)


class NativeStampBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        class Stamper:
            calls = []

            @classmethod
            def set_external_generator(cls, *args, **kwargs):
                cls.calls.append((args, kwargs))

        self.stamper = Stamper
        self.bridge = load_bridge(Stamper)

    def configure_native_jobs(
        self,
        *,
        start=None,
        poll=None,
        cancel=None,
        release=None,
        cancel_all=None,
    ) -> None:
        setattr(self.bridge, "_stamp_job_start_fn", start or mock.Mock(return_value=1))
        setattr(self.bridge, "_stamp_job_poll_fn", poll or mock.Mock(return_value=-2))
        setattr(self.bridge, "_stamp_job_cancel_fn", cancel or mock.Mock(return_value=0))
        setattr(self.bridge, "_stamp_job_release_fn", release or mock.Mock(return_value=0))
        setattr(
            self.bridge,
            "_stamp_jobs_cancel_all_fn",
            cancel_all or mock.Mock(return_value=0),
        )

    def test_token_cancellation_cancels_and_releases_native_job(self) -> None:
        class Token:
            def __init__(self):
                self.checks = 0

            def is_cancelled(self):
                self.checks += 1
                return True

        token = Token()
        events = []

        def start(workblock, length, cost):
            events.append(("start", bytes(workblock), length, cost))
            return 41

        def cancel(job_id):
            events.append(("cancel", job_id))
            return 0

        def poll(job_id, _output):
            events.append(("poll", job_id))
            return -2

        def release(job_id):
            events.append(("release", job_id))
            return 0

        self.configure_native_jobs(start=start, poll=poll, cancel=cancel, release=release)
        self.assertIsNone(self.bridge._native_stamp_pow(b"work", 9, token))
        self.assertEqual(
            [
                ("start", b"work", 4, 9),
                ("cancel", 41),
                ("poll", 41),
                ("release", 41),
            ],
            events,
        )
        self.assertEqual(1, token.checks)

    def test_valid_nonzero_cost_native_job_returns_exact_stamp(self) -> None:
        workblock = b"payload"
        cost = 7
        candidate_number = 0
        while True:
            expected = candidate_number.to_bytes(32, "big")
            digest = hashlib.sha256(workblock + expected).digest()
            leading_zeros = 256 - int.from_bytes(digest, "big").bit_length()
            if leading_zeros >= cost:
                break
            candidate_number += 1

        released = []

        def poll(job_id, output):
            self.assertEqual(73, job_id)
            ctypes.memmove(output, expected, len(expected))
            return len(expected)

        self.configure_native_jobs(
            start=mock.Mock(return_value=73),
            poll=poll,
            release=lambda job_id: released.append(job_id) or 0,
        )
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        stamp = self.bridge._native_stamp_pow(workblock, cost, token)
        self.assertEqual(expected, stamp)
        self.assertEqual([73], released)
        proof = hashlib.sha256(workblock + stamp).digest()
        self.assertGreaterEqual(256 - int.from_bytes(proof, "big").bit_length(), cost)

    def test_unexpected_positive_poll_status_fails_closed(self) -> None:
        polls = []
        released = []

        def poll(job_id, _output):
            polls.append(job_id)
            return 1 if len(polls) == 1 else -2

        self.configure_native_jobs(
            start=mock.Mock(return_value=91),
            poll=poll,
            release=lambda job_id: released.append(job_id) or 0,
        )
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        self.assertIsNone(self.bridge._native_stamp_pow(b"work", 8, token))
        self.assertEqual([91], polls)
        self.assertEqual([91], released)

    def test_install_requests_three_argument_contract_and_forwards_exact_token(self) -> None:
        token = object()
        self.configure_native_jobs()
        self.bridge._native_stamp_pow = mock.Mock(return_value=b"x" * 32)

        self.bridge._install_native_stamp_generator()
        args, kwargs = self.stamper.calls[-1]
        self.assertEqual({"pass_cancellation_token": True}, kwargs)
        self.assertEqual(1, len(args))
        self.assertEqual((b"x" * 32, 0), args[0](b"block", 5, token))
        self.bridge._native_stamp_pow.assert_called_once_with(b"block", 5, token)

    def test_repeated_install_uninstall_does_not_retain_global_callback(self) -> None:
        self.configure_native_jobs()
        for _ in range(2):
            self.bridge._install_native_stamp_generator()
            self.bridge._uninstall_native_stamp_generator()
        self.assertIsNone(self.stamper.calls[-1][0][0])
        self.assertEqual(4, len(self.stamper.calls))

    def test_cancel_all_failure_does_not_retain_global_callback(self) -> None:
        self.configure_native_jobs(cancel_all=mock.Mock(side_effect=RuntimeError("boom")))
        self.bridge._install_native_stamp_generator()
        self.bridge._uninstall_native_stamp_generator()
        self.assertIsNone(self.stamper.calls[-1][0][0])

    def test_repeated_stop_when_not_started_still_clears_global_callback(self) -> None:
        self.configure_native_jobs()
        self.bridge._install_native_stamp_generator()
        self.bridge._state["started"] = False
        self.bridge.stop()
        self.bridge.stop()
        self.assertIsNone(self.stamper.calls[-1][0][0])
        self.assertEqual(3, len(self.stamper.calls))

    def test_teardown_during_registration_clears_new_callback(self) -> None:
        self.bridge._runtime_teardown_requested.clear()

        def install_then_request_teardown():
            self.bridge._runtime_teardown_requested.set()

        with mock.patch.object(
            self.bridge,
            "_install_native_stamp_generator",
            side_effect=install_then_request_teardown,
        ) as install, mock.patch.object(
            self.bridge, "_uninstall_native_stamp_generator"
        ) as uninstall:
            installed = self.bridge._install_native_stamp_generator_unless_stopping()

        self.assertFalse(installed)
        install.assert_called_once_with()
        uninstall.assert_called_once_with()

    def test_pending_teardown_prevents_registration(self) -> None:
        self.bridge._runtime_teardown_requested.set()
        with mock.patch.object(self.bridge, "_install_native_stamp_generator") as install:
            installed = self.bridge._install_native_stamp_generator_unless_stopping()
        self.assertFalse(installed)
        install.assert_not_called()

    def test_stop_balances_teardown_publication_when_cleanup_raises(self) -> None:
        with mock.patch.object(
            self.bridge,
            "_clear_transport_class_state",
            side_effect=RuntimeError("injected stop cleanup failure"),
        ):
            with self.assertRaisesRegex(RuntimeError, "injected stop cleanup failure"):
                self.bridge.stop()
        self.assertEqual(0, self.bridge._runtime_teardown_count)
        self.assertFalse(self.bridge._runtime_teardown_requested.is_set())

    def test_reset_balances_teardown_publication_when_cleanup_raises(self) -> None:
        with mock.patch.object(
            self.bridge,
            "_clear_transport_class_state",
            side_effect=RuntimeError("injected reset cleanup failure"),
        ):
            with self.assertRaisesRegex(RuntimeError, "injected reset cleanup failure"):
                self.bridge.reset_identity("/tmp/nonexistent-columba-test-identity")
        self.assertEqual(0, self.bridge._runtime_teardown_count)
        self.assertFalse(self.bridge._runtime_teardown_requested.is_set())


class NativeStampStaticABITests(unittest.TestCase):
    def test_shipping_stamp_bridge_uses_no_python_callback_trampoline(self) -> None:
        forbidden = re.compile(r"\b(?:CFUNCTYPE|PYFUNCTYPE)\b")
        offenders = []
        for path in sorted((ROOT / "app").rglob("*.py")):
            if forbidden.search(path.read_text(encoding="utf-8")):
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual([], offenders, "shipping Python creates a native callback trampoline")

    def test_swift_has_native_job_abi_and_thread_safe_periodic_polling(self) -> None:
        source = STAMP.read_text(encoding="utf-8")
        for symbol in (
            "columba_stamp_generate",
            "columba_stamp_job_start",
            "columba_stamp_job_poll",
            "columba_stamp_job_cancel",
            "columba_stamp_job_release",
            "columba_stamp_jobs_cancel_all",
        ):
            self.assertIn(f'@_cdecl("{symbol}")', source)
        self.assertNotIn("columba_stamp_generate_cancellable", source)
        self.assertNotIn("@convention(c)", source)
        self.assertIn("StampCancellationState", source)
        self.assertRegex(source, r"rounds\s*&\s*0x(?:FF|[1-9A-F][0-9A-F]+)\s*==\s*0")
        self.assertIn("OSAllocatedUnfairLock", source)
        self.assertIn("func poll(into outStamp:", source)
        self.assertNotRegex(source, r"nonatomic|UnsafeMutablePointer<Bool>")

    def test_shutdown_paths_unregister_before_taking_bridge_lock(self) -> None:
        source = BRIDGE.read_text(encoding="utf-8")
        for function in ("stop", "reset_identity"):
            body = source[source.index(f"def {function}("):]
            body = body.split("\ndef ", 1)[0]
            self.assertLess(body.index("_uninstall_native_stamp_generator()"), body.index("with _lock:"))


if __name__ == "__main__":
    unittest.main()
