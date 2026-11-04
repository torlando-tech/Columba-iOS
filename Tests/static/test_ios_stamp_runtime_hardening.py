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



class NativeJobFixture:
    """Exercise the FFI boundary with real SHA-256 proofs and owned jobs."""

    def __init__(self):
        self.starts = []
        self.jobs = {}
        self.released = []
        self.cancelled = []
        self.after_poll = None

    def start_target(self, workblock, length, target, target_length):
        payload = ctypes.string_at(workblock, length)
        target_bytes = ctypes.string_at(target, target_length)
        self.starts.append(("target", payload, target_bytes))
        if target_length != 32:
            return 0
        return self._start(payload, int.from_bytes(target_bytes, "big"))

    def start_integer(self, workblock, length, cost):
        payload = ctypes.string_at(workblock, length)
        self.starts.append(("integer", payload, cost))
        if not isinstance(cost, int) or not 0 <= cost <= 32:
            return 0
        return self._start(payload, (1 << (256 - cost)) - 1)

    def _start(self, payload, target):
        job_id = len(self.starts)
        # High-cost serialization tests need not mine a four-billion-round proof.
        if target < (1 << 240):
            return 0
        for number in range(100_000):
            stamp = number.to_bytes(32, "big")
            if int.from_bytes(hashlib.sha256(payload + stamp).digest(), "big") <= target:
                self.jobs[job_id] = stamp
                return job_id
        raise AssertionError("fixture did not find an inexpensive stamp")

    def poll(self, job_id, output):
        if job_id in self.cancelled:
            return -2
        ctypes.memmove(output, self.jobs[job_id], 32)
        if self.after_poll is not None:
            self.after_poll()
        return 32

    def cancel(self, job_id):
        self.cancelled.append(job_id)
        return 0

    def release(self, job_id):
        self.released.append(job_id)
        self.jobs.pop(job_id, None)
        return 0


def fractional_stamps():
    # Published upstream vectors; the helper receives raw, not pre-rounded costs.
    targets = {
        0: 1 << 256,
        8: int("0100000000000000000000000000000000000000000000000000000000000000", 16),
        8.5: int("00b504f333c00000000000000000000000000000000000000000000000000000", 16),
        31.999: int("0000000100000000000000000000000000000000000000000000000000000000", 16),
        32: int("0000000100000000000000000000000000000000000000000000000000000000", 16),
    }
    return types.SimpleNamespace(target_from_cost=lambda cost: targets[cost])

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

    def configure_proof_jobs(self, *, target_api=True, integer_api=True):
        jobs = NativeJobFixture()
        self.configure_native_jobs(
            start=jobs.start_integer,
            poll=jobs.poll,
            cancel=jobs.cancel,
            release=jobs.release,
        )
        self.bridge._stamp_job_start_fn = jobs.start_integer if integer_api else None
        self.bridge._stamp_job_start_target_fn = jobs.start_target if target_api else None
        return jobs

    def test_fractional_target_only_binary_returns_valid_proof(self) -> None:
        self.bridge.RNS.Stamps = fractional_stamps()
        jobs = self.configure_proof_jobs(integer_api=False)
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        stamp = self.bridge._native_stamp_pow(b"fractional-work", 8.5, token)
        self.assertIsNotNone(stamp)
        target = bytes.fromhex(
            "00b504f333c00000000000000000000000000000000000000000000000000000"
        )
        self.assertEqual([("target", b"fractional-work", target)], jobs.starts)
        self.assertLessEqual(hashlib.sha256(b"fractional-work" + stamp).digest(), target)
        self.assertEqual([1], jobs.released)

    def test_authoritative_target_keeps_exact_digest_boundary(self) -> None:
        workblock = b"target-boundary"
        boundary = hashlib.sha256(workblock + bytes(32)).digest()
        self.bridge.RNS.Stamps = types.SimpleNamespace(
            target_from_cost=lambda _cost: int.from_bytes(boundary, "big")
        )
        jobs = self.configure_proof_jobs()
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        self.assertEqual(bytes(32), self.bridge._native_stamp_pow(workblock, 8.5, token))
        self.assertEqual([("target", workblock, boundary)], jobs.starts)
        self.assertEqual([1], jobs.released)

    def test_old_dependency_integral_cost_works_with_either_native_api(self) -> None:
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        for target_api in (False, True):
            with self.subTest(target_api=target_api):
                jobs = self.configure_proof_jobs(target_api=target_api)
                stamp = self.bridge._native_stamp_pow(b"integer-work", 8.0, token)
                self.assertIsNotNone(stamp)
                digest = int.from_bytes(hashlib.sha256(b"integer-work" + stamp).digest(), "big")
                self.assertLessEqual(digest, 1 << 248)
                if target_api:
                    self.assertEqual((1 << 248).to_bytes(32, "big"), jobs.starts[0][2])
                else:
                    self.assertEqual(8, jobs.starts[0][2])
                self.assertEqual([1], jobs.released)

    def test_old_binary_ceil_cost_never_truncates_fraction(self) -> None:
        self.bridge.RNS.Stamps = fractional_stamps()
        jobs = self.configure_proof_jobs(target_api=False)
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        stamp = self.bridge._native_stamp_pow(b"ceil-work", 8.5, token)
        self.assertIsNotNone(stamp)
        self.assertEqual([("integer", b"ceil-work", 9)], jobs.starts)
        self.assertLess(int.from_bytes(hashlib.sha256(b"ceil-work" + stamp).digest(), "big"), 1 << 247)
        self.assertEqual([1], jobs.released)

    def test_old_dependency_fraction_fails_without_starting_work(self) -> None:
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        for target_api in (False, True):
            with self.subTest(target_api=target_api):
                jobs = self.configure_proof_jobs(target_api=target_api)
                self.assertIsNone(self.bridge._native_stamp_pow(b"work", 8.5, token))
                self.assertEqual([], jobs.starts)
                self.assertEqual([], jobs.released)
        self.assertTrue(self.bridge.RNS.log.called)

    def test_raw_cost_quantization_and_cap_use_authoritative_target(self) -> None:
        self.bridge.RNS.Stamps = fractional_stamps()
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        for cost in (31.999, 32):
            with self.subTest(cost=cost):
                jobs = self.configure_proof_jobs()
                self.assertIsNone(self.bridge._native_stamp_pow(b"work", cost, token))
                self.assertEqual(
                    bytes.fromhex("0000000100000000000000000000000000000000000000000000000000000000"),
                    jobs.starts[0][2],
                )
                self.assertEqual([], jobs.released)

    def test_zero_cost_target_is_clamped_and_returns_zero_stamp(self) -> None:
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        for stamps in (None, fractional_stamps()):
            with self.subTest(helper_available=stamps is not None):
                self.bridge.RNS.Stamps = stamps
                jobs = self.configure_proof_jobs()
                self.assertEqual(bytes(32), self.bridge._native_stamp_pow(b"work", 0, token))
                self.assertEqual(bytes([255]) * 32, jobs.starts[0][2])
                self.assertEqual([1], jobs.released)

    def test_invalid_cost_fails_before_work_or_ffi(self) -> None:
        class UnreadableWork:
            def __bytes__(self):
                raise AssertionError("invalid cost must be rejected before work")

        self.bridge.RNS.Stamps = fractional_stamps()
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        for target_api in (False, True):
            invalid_costs = (
                float("nan"), float("inf"), -float("inf"), -1, 32.001, 33,
                2**100, 2**10000, None, "8.5",
            )
            for index, cost in enumerate(invalid_costs):
                with self.subTest(target_api=target_api, case=index):
                    jobs = self.configure_proof_jobs(target_api=target_api)
                    self.assertIsNone(self.bridge._native_stamp_pow(UnreadableWork(), cost, token))
                    self.assertEqual([], jobs.starts)

    def test_fractional_completed_proof_loses_cancellation_race(self) -> None:
        self.bridge.RNS.Stamps = fractional_stamps()
        jobs = self.configure_proof_jobs()
        token = types.SimpleNamespace(cancelled=False)
        token.is_cancelled = lambda: token.cancelled
        jobs.after_poll = lambda: setattr(token, "cancelled", True)
        self.assertIsNone(self.bridge._native_stamp_pow(b"race-work", 8.5, token))
        self.assertEqual([1], jobs.cancelled)
        self.assertEqual([1], jobs.released)

    def test_poll_exception_still_releases_fractional_job(self) -> None:
        self.bridge.RNS.Stamps = fractional_stamps()
        jobs = self.configure_proof_jobs()

        def fail_poll():
            raise RuntimeError("native poll failed")

        jobs.after_poll = fail_poll
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        with self.assertRaisesRegex(RuntimeError, "native poll failed"):
            self.bridge._native_stamp_pow(b"cleanup-work", 8.5, token)
        self.assertEqual([1], jobs.released)


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

    def test_registered_generator_returns_fractionally_valid_stamp_and_cancels(self) -> None:
        self.bridge.RNS.Stamps = fractional_stamps()
        jobs = self.configure_proof_jobs()
        token = types.SimpleNamespace(cancelled=False)
        token.is_cancelled = lambda: token.cancelled
        self.bridge._install_native_stamp_generator()
        args, kwargs = self.stamper.calls[-1]
        self.assertEqual({"pass_cancellation_token": True}, kwargs)
        generator = args[0]
        stamp, rounds = generator(b"registered-work", 8.5, token)
        self.assertEqual(0, rounds)
        self.assertIsNotNone(stamp)
        target = bytes.fromhex("00b504f333c00000000000000000000000000000000000000000000000000000")
        self.assertEqual(target, jobs.starts[0][2])
        self.assertLessEqual(hashlib.sha256(b"registered-work" + stamp).digest(), target)
        jobs.after_poll = lambda: setattr(token, "cancelled", True)
        self.assertEqual((None, 0), generator(b"registered-race", 8.5, token))
        self.assertEqual([2], jobs.cancelled)
        self.assertEqual([1, 2], jobs.released)

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

    def test_shutdown_paths_unregister_before_taking_bridge_lock(self) -> None:
        source = BRIDGE.read_text(encoding="utf-8")
        for function in ("stop", "reset_identity"):
            body = source[source.index(f"def {function}("):]
            body = body.split("\ndef ", 1)[0]
            self.assertLess(body.index("_uninstall_native_stamp_generator()"), body.index("with _lock:"))


if __name__ == "__main__":
    unittest.main()
