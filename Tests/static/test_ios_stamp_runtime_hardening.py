#!/usr/bin/env python3
"""Portable behavioral regressions for the iOS native hash-search boundary."""

from __future__ import annotations

import ctypes
import hashlib
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest import mock

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat


ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app" / "rns_bridge.py"


def load_bridge():
    rns = types.ModuleType("RNS")
    rns.LOG_DEBUG = 0
    rns.LOG_WARNING = 1
    rns.LOG_INFO = 2
    rns.LOG_VERBOSE = 3
    rns.LOG_ERROR = 4
    rns.log = mock.Mock()
    active_jobs = {}

    def cancel_work(message_id):
        if message_id not in active_jobs:
            return False
        active_jobs[message_id] = True
        return True

    rns.Stamps = types.SimpleNamespace(
        native_stamp_search=None, native_key_search=None, active_jobs=active_jobs,
        cancel_work=cancel_work,
    )
    rns.Transport = types.SimpleNamespace(
        destinations=[], interfaces=[], path_table={}, destination_table={},
        announce_handlers=[], identities={}, deregister_announce_handler=mock.Mock(),
    )
    rns.Reticulum = type("Reticulum", (), {})
    lxmf = types.ModuleType("LXMF")
    name = f"rns_bridge_stamp_test_{id(rns)}"
    spec = importlib.util.spec_from_file_location(name, BRIDGE)
    module = importlib.util.module_from_spec(spec)
    old_stdout = sys.stdout
    try:
        with mock.patch.dict(sys.modules, {"RNS": rns, "LXMF": lxmf}):
            assert spec.loader is not None
            spec.loader.exec_module(module)
    finally:
        sys.stdout = old_stdout
    return module


class NativeJobFixture:
    """Signed-job boundary substitute with SHA-256 proofs and terminal counts."""

    def __init__(self):
        self.starts = []
        self.jobs = {}
        self.released = []
        self.cancelled = []
        self.after_poll = None
        self.after_start = None
        self.running_polls = 0
        self.failure = None
        self.cancel_all_calls = 0

    def start(self, workblock, length, target, target_length, size):
        payload = ctypes.string_at(workblock, length)
        target_bytes = ctypes.string_at(target, target_length)
        self.starts.append((payload, target_bytes, size))
        if target_length != 32:
            return 0
        boundary = int.from_bytes(target_bytes, "big")
        # Very small targets only exercise serialization, not expensive mining.
        if boundary < (1 << 240):
            return 0
        for rounds in range(100_000):
            stamp = rounds.to_bytes(size, "big")
            if int.from_bytes(hashlib.sha256(payload + stamp).digest(), "big") <= boundary:
                job_id = len(self.starts)
                self.jobs[job_id] = (stamp, rounds)
                if self.after_start is not None:
                    self.after_start()
                return job_id
        raise AssertionError("fixture did not find an inexpensive proof")

    def poll(self, job_id, output, capacity, out_rounds):
        stamp, rounds = self.jobs[job_id]
        ctypes.cast(out_rounds, ctypes.POINTER(ctypes.c_uint64))[0] = rounds
        if job_id in self.cancelled:
            return -2
        if self.failure is not None:
            return self.failure
        if self.running_polls:
            self.running_polls -= 1
            return 0
        if capacity < len(stamp):
            return -1
        ctypes.memmove(output, stamp, len(stamp))
        if self.after_poll is not None:
            self.after_poll()
        return len(stamp)

    def cancel(self, job_id):
        self.cancelled.append(job_id)
        return 0

    def cancel_all(self):
        self.cancel_all_calls += 1
        self.cancelled.extend(self.jobs)
        return 0

    def release(self, job_id):
        self.released.append(job_id)
        self.jobs.pop(job_id, None)
        return 0


class NativeStampBridgeTests(unittest.TestCase):
    def setUp(self):
        self.bridge = load_bridge()
        self.jobs = NativeJobFixture()
        for suffix, function in (
            ("start", self.jobs.start), ("poll", self.jobs.poll),
            ("cancel", self.jobs.cancel), ("release", self.jobs.release),
        ):
            setattr(self.bridge, f"_stamp_job_{suffix}_fn", function)
        self.bridge._stamp_jobs_cancel_all_fn = self.jobs.cancel_all
        self.assertTrue(self.bridge._install_native_stamp_search_unless_stopping())
        self.search = self.bridge.RNS.Stamps.native_stamp_search

    def test_registered_search_returns_valid_variable_length_proofs_and_true_rounds(self):
        for size in (1, 14, 32, 65):
            with self.subTest(size=size):
                workblock = b"candidate-size"
                target = (1 << 255) if size == 1 else (1 << 248)
                stamp, rounds = self.search(workblock, target, size, lambda: False)
                self.assertEqual(size, len(stamp))
                self.assertLessEqual(
                    int.from_bytes(hashlib.sha256(workblock + stamp).digest(), "big"),
                    target,
                )
                # The fixture enumerates candidate integers, so its proof itself
                # independently identifies the number of failed attempts.
                self.assertEqual(int.from_bytes(stamp, "big"), rounds)
                self.assertGreater(rounds, 0)
        self.assertEqual([1, 2, 3, 4], self.jobs.released)
        self.assertEqual({}, self.jobs.jobs)

    def test_exact_digest_boundary_is_inclusive(self):
        workblock = b"exact-boundary"
        target = int.from_bytes(hashlib.sha256(workblock + bytes(14)).digest(), "big")
        self.assertEqual((bytes(14), 0), self.search(workblock, target, 14, lambda: False))
        self.assertEqual([1], self.jobs.released)

    def test_cost_zero_target_clamps_to_full_width(self):
        self.assertEqual((bytes(32), 0), self.search(b"work", 1 << 256, 32, lambda: False))
        self.assertEqual(bytes([255]) * 32, self.jobs.starts[0][1])

    def test_full_target_below_old_cost_floor_is_not_changed(self):
        target = 0x123456789ABCDEF
        self.assertEqual((None, 0), self.search(b"work", target, 14, lambda: False))
        self.assertEqual(target.to_bytes(32, "big"), self.jobs.starts[0][1])
        self.assertEqual([], self.jobs.released)

    def test_running_poll_waits_for_terminal_rounds(self):
        self.jobs.running_polls = 1
        stamp, rounds = self.search(b"running", 1 << 248, 14, lambda: False)
        self.assertEqual(int.from_bytes(stamp, "big"), rounds)
        self.assertEqual([1], self.jobs.released)

    def test_stop_check_cancels_and_keeps_terminal_rounds(self):
        self.assertEqual((None, 127), self.search(b"candidate-size", 1 << 248, 14, lambda: True))
        self.assertEqual([1], self.jobs.cancelled)
        self.assertEqual([1], self.jobs.released)

    def test_completed_proof_loses_cancellation_race(self):
        cancelled = False

        def cancel_after_poll():
            nonlocal cancelled
            cancelled = True

        self.jobs.after_poll = cancel_after_poll
        self.assertEqual((None, 127), self.search(b"candidate-size", 1 << 248, 14, lambda: cancelled))
        self.assertEqual([1], self.jobs.cancelled)
        self.assertEqual([1], self.jobs.released)

    def test_native_failures_release_and_preserve_rounds(self):
        for failure in (-1, -2, -3, 15):
            with self.subTest(failure=failure):
                self.jobs.failure = failure
                self.assertEqual((None, 127), self.search(b"candidate-size", 1 << 248, 14, lambda: False))
        self.assertEqual([1, 2, 3, 4], self.jobs.released)

    def test_poll_exception_still_releases_job(self):
        def fail_poll():
            raise RuntimeError("native poll failed")

        self.jobs.after_poll = fail_poll
        with self.assertRaisesRegex(RuntimeError, "native poll failed"):
            self.search(b"work", 1 << 256, 14, lambda: False)
        self.assertEqual([1], self.jobs.released)

    def test_stop_check_exception_still_releases_job(self):
        def fail_stop_check():
            raise RuntimeError("stop check failed")

        with self.assertRaisesRegex(RuntimeError, "stop check failed"):
            self.search(b"work", 1 << 256, 14, fail_stop_check)
        self.assertEqual([1], self.jobs.released)

    def test_buffer_allocation_failure_still_releases_job(self):
        with mock.patch.object(self.bridge.ctypes, "create_string_buffer", side_effect=MemoryError):
            with self.assertRaises(MemoryError):
                self.search(b"work", 1 << 256, 14, lambda: False)
        self.assertEqual([1], self.jobs.released)

    def test_zero_size_uses_python_search_and_retains_empty_proof(self):
        self.bridge.RNS.Stamps._loop_hash = lambda *_args: (b"", 0, True)
        self.assertEqual((b"", 0), self.search(b"work", 1 << 256, 0, lambda: False))
        self.assertEqual([], self.jobs.starts)

    def test_out_of_range_size_does_not_return_unfound_python_candidate(self):
        self.bridge.RNS.Stamps._loop_hash = lambda *_args: (b"unfound", 7, False)
        self.assertEqual((None, 7), self.search(b"work", 0, 1 << 31, lambda: True))
        self.assertEqual([], self.jobs.starts)

    def test_missing_native_symbol_does_not_register_or_log_success(self):
        self.bridge._uninstall_native_stamp_search()
        self.bridge._stamp_job_start_fn = None
        self.bridge.RNS.log.reset_mock()
        self.assertFalse(self.bridge._install_native_stamp_search_unless_stopping())
        self.assertIsNone(self.bridge.RNS.Stamps.native_stamp_search)
        self.assertEqual(self.bridge.RNS.LOG_ERROR, self.bridge.RNS.log.call_args.args[1])
        self.assertIn("required native job symbols", self.bridge.RNS.log.call_args.args[0])

    def test_missing_rns_hook_does_not_log_success(self):
        del self.bridge.RNS.Stamps.native_stamp_search
        self.bridge.RNS.log.reset_mock()
        self.assertFalse(self.bridge._install_native_stamp_search_unless_stopping())
        self.assertEqual(self.bridge.RNS.LOG_ERROR, self.bridge.RNS.log.call_args.args[1])

    def test_repeated_stop_before_start_detaches_hook_and_cancels_all(self):
        self.bridge.stop()
        self.bridge.stop()
        self.assertIsNone(self.bridge.RNS.Stamps.native_stamp_search)
        self.assertEqual(2, self.jobs.cancel_all_calls)

    def test_stop_during_native_search_cancels_and_releases_active_job(self):
        self.jobs.after_start = self.bridge.stop
        self.assertEqual((None, 127), self.search(b"candidate-size", 1 << 248, 14, lambda: False))
        self.assertIsNone(self.bridge.RNS.Stamps.native_stamp_search)
        self.assertEqual({}, self.jobs.jobs)
        self.assertEqual([1], self.jobs.released)

    def test_stop_before_native_allocation_cancels_the_late_handle(self):
        stamps = self.bridge.RNS.Stamps
        message_id = b"paused-before-native-start"
        stamps.active_jobs[message_id] = False

        def start_after_stop(*args):
            self.bridge.stop()
            self.assertFalse(self.bridge._runtime_teardown_requested.is_set())
            self.assertEqual({}, self.jobs.jobs)
            return self.jobs.start(*args)

        self.bridge._stamp_job_start_fn = start_after_stop
        self.assertEqual(
            (None, 127),
            self.search(
                b"candidate-size", 1 << 248, 14,
                lambda: stamps.active_jobs[message_id],
            ),
        )
        self.assertTrue(stamps.active_jobs[message_id])
        self.assertIsNone(stamps.native_stamp_search)
        self.assertEqual([1], self.jobs.cancelled)
        self.assertEqual([1], self.jobs.released)
        self.assertEqual({}, self.jobs.jobs)

    def test_rns_cancellation_failure_does_not_skip_other_jobs_or_native_cleanup(self):
        stamps = self.bridge.RNS.Stamps
        stamps.active_jobs.update({b"failed": False, b"other": False})
        cancel_work = stamps.cancel_work

        def fail_first_cancellation(message_id):
            if message_id == b"failed":
                raise RuntimeError("RNS cancellation failed")
            return cancel_work(message_id)

        stamps.cancel_work = fail_first_cancellation
        self.bridge.stop()
        self.assertTrue(stamps.active_jobs[b"other"])
        self.assertIsNone(stamps.native_stamp_search)
        self.assertEqual(1, self.jobs.cancel_all_calls)

    def test_cancel_all_failure_does_not_retain_hook(self):
        def fail_cancel_all():
            raise RuntimeError("cancel-all failed")

        self.bridge._stamp_jobs_cancel_all_fn = fail_cancel_all
        self.bridge.stop()
        self.assertIsNone(self.bridge.RNS.Stamps.native_stamp_search)

    def test_teardown_during_registration_detaches_new_hook(self):
        class Stamps:
            native_stamp_search = None
            active_jobs = {}

            def __setattr__(self, name, value):
                object.__setattr__(self, name, value)
                if value is not None:
                    self_bridge._runtime_teardown_requested.set()

        self_bridge = self.bridge
        self.bridge.RNS.Stamps = Stamps()
        self.assertFalse(self.bridge._install_native_stamp_search_unless_stopping())
        self.assertIsNone(self.bridge.RNS.Stamps.native_stamp_search)
        self.assertEqual(1, self.jobs.cancel_all_calls)

    def test_pending_teardown_prevents_registration_and_new_jobs(self):
        self.bridge._uninstall_native_stamp_search()
        self.bridge._runtime_teardown_requested.set()
        self.assertFalse(self.bridge._install_native_stamp_search_unless_stopping())
        self.assertIsNone(self.bridge.RNS.Stamps.native_stamp_search)
        self.assertEqual((None, 0), self.search(b"work", 1 << 256, 14, lambda: False))
        self.assertEqual([], self.jobs.starts)

    def test_stop_balances_teardown_publication_when_cleanup_raises(self):
        with mock.patch.object(
            self.bridge, "_clear_transport_class_state",
            side_effect=RuntimeError("injected stop cleanup failure"),
        ):
            with self.assertRaisesRegex(RuntimeError, "injected stop cleanup failure"):
                self.bridge.stop()
        self.assertEqual(0, self.bridge._runtime_teardown_count)
        self.assertFalse(self.bridge._runtime_teardown_requested.is_set())

    def test_reset_balances_teardown_publication_when_cleanup_raises(self):
        with mock.patch.object(
            self.bridge, "_clear_transport_class_state",
            side_effect=RuntimeError("injected reset cleanup failure"),
        ):
            with self.assertRaisesRegex(RuntimeError, "injected reset cleanup failure"):
                self.bridge.reset_identity("/tmp/nonexistent-columba-test-identity")
        self.assertEqual(0, self.bridge._runtime_teardown_count)
        self.assertFalse(self.bridge._runtime_teardown_requested.is_set())


class NativeKeyJobFixture(NativeJobFixture):
    """Key-stamp variant: real X25519 keypairs behind the same signed-job poll."""

    def start(self, material, length, target, target_length):
        payload = ctypes.string_at(material, length)
        target_bytes = ctypes.string_at(target, target_length)
        self.starts.append((payload, target_bytes, 64))
        if target_length != 32:
            return 0
        boundary = int.from_bytes(target_bytes, "big")
        if boundary < (1 << 240):
            return 0
        for rounds in range(100_000):
            private = X25519PrivateKey.generate()
            public = private.public_key().public_bytes(
                encoding=Encoding.Raw, format=PublicFormat.Raw
            )
            if int.from_bytes(hashlib.sha256(payload + public).digest(), "big") <= boundary:
                job_id = len(self.starts)
                self.jobs[job_id] = (
                    private.private_bytes(
                        encoding=Encoding.Raw,
                        format=PrivateFormat.Raw,
                        encryption_algorithm=NoEncryption(),
                    ) + public,
                    rounds,
                )
                if self.after_start is not None:
                    self.after_start()
                return job_id
        raise AssertionError("fixture did not find an inexpensive keypair")


class NativeKeyStampBridgeTests(unittest.TestCase):
    def setUp(self):
        self.bridge = load_bridge()
        self.jobs = NativeKeyJobFixture()
        self.bridge._key_stamp_job_start_fn = self.jobs.start
        for suffix, function in (
            ("poll", self.jobs.poll), ("cancel", self.jobs.cancel),
            ("release", self.jobs.release),
        ):
            setattr(self.bridge, f"_stamp_job_{suffix}_fn", function)
        self.bridge._stamp_jobs_cancel_all_fn = self.jobs.cancel_all
        # The hash hook must stay installable: key search registers under an
        # independent guard beside it.
        self.bridge._stamp_job_start_fn = (
            lambda workblock, length, target, target_length, size:
            self.jobs.start(workblock, length, target, target_length)
        )
        self.assertTrue(self.bridge._install_native_stamp_search_unless_stopping())
        self.search = self.bridge.RNS.Stamps.native_key_search

    def test_registered_key_search_returns_real_derivable_keypair(self):
        keypair, rounds = self.search(b"material", 1 << 248, lambda: False)
        private, public = keypair
        self.assertEqual(32, len(private))
        self.assertEqual(32, len(public))
        self.assertEqual(
            X25519PrivateKey.from_private_bytes(private).public_key().public_bytes(
                encoding=Encoding.Raw, format=PublicFormat.Raw
            ),
            public,
        )
        self.assertGreater(rounds, 0)
        self.assertEqual([1], self.jobs.released)
        self.assertEqual({}, self.jobs.jobs)

    def test_key_stop_check_cancels_and_returns_none(self):
        self.assertIsNone(self.search(b"material", 1 << 248, lambda: True)[0])
        self.assertEqual([1], self.jobs.cancelled)
        self.assertEqual([1], self.jobs.released)

    def test_missing_key_symbol_keeps_hash_search_registered(self):
        self.bridge._uninstall_native_stamp_search()
        self.bridge._key_stamp_job_start_fn = None
        self.assertTrue(self.bridge._install_native_stamp_search_unless_stopping())
        self.assertIsNone(self.bridge.RNS.Stamps.native_key_search)
        self.assertIsNotNone(self.bridge.RNS.Stamps.native_stamp_search)

    def test_uninstall_clears_both_hooks_and_cancels_key_jobs(self):
        self.search(b"material", 1 << 248, lambda: False)
        self.bridge._uninstall_native_stamp_search()
        self.assertIsNone(self.bridge.RNS.Stamps.native_key_search)
        self.assertIsNone(self.bridge.RNS.Stamps.native_stamp_search)
        self.assertEqual(1, self.jobs.cancel_all_calls)
        self.assertEqual({}, self.jobs.jobs)


class StampHookAttributionTests(unittest.TestCase):
    """Which search hook wins must reach diag.log, not only RNS.log.

    A cost-18 link stamp measured 39.4k rounds/s on device (about one core at
    32.8k/core) and RNS's debug line never reaches diag.log, so the page-fetch
    runtime had no way to show whether the native hook was even registered.
    """

    def test_install_records_which_hook_wins(self) -> None:
        bridge = BRIDGE.read_text()
        install = bridge.split("def _install_native_stamp_search", 1)[1]
        install = install.split("def _uninstall_native_stamp_search", 1)[0]
        self.assertIn('_diag_append(', install)
        self.assertIn("[STAMP-HOOK]", install)

    def test_key_search_records_rounds_and_duration(self) -> None:
        bridge = BRIDGE.read_text()
        search = bridge.split("def _native_key_search", 1)[1]
        search = search.split("def _install_native_stamp_search", 1)[0]
        self.assertIn("[STAMP-KEY]", search)
        self.assertIn("rounds={rounds.value}", search)


class KeyStampHostSeamContractTests(unittest.TestCase):
    """Page-link key stamps must run where the cores are.

    Measured on device: the NE's native kernel does 39.4k rounds/s (one
    efficiency core's worth) while the app runs 32.8k rounds/s per core, so a
    cost-18 link stamp cost ~7s inside the NE. `_native_key_search` asks the app
    over the App-Group seam and only falls back to the in-process kernel when no
    host answers.
    """

    def setUp(self) -> None:
        self.source = BRIDGE.read_text()
        self.search = self.source.split("def _native_key_search", 1)[1].split(
            "def _install_native_stamp_search", 1
        )[0]

    def test_host_symbols_are_bound(self) -> None:
        for symbol in (
            "columba_host_key_stamp_job_start",
            "columba_host_key_stamp_job_poll",
            "columba_host_key_stamp_job_cancel",
            "columba_host_key_stamp_job_release",
        ):
            self.assertIn('"%s"' % symbol, self.source)

    def test_host_start_precedes_the_local_kernel(self) -> None:
        host = self.search.index("_host_key_stamp_job_start_fn(")
        local = self.search.index("_key_stamp_job_start_fn(payload")
        self.assertLess(host, local)
        self.assertIn('via = "app"', self.search)
        self.assertIn('via = "local"', self.search)

    def test_stalled_host_falls_back_to_the_in_process_kernel(self) -> None:
        # A suspended app accepts the job and then freezes; without -4 the NE
        # would wait out the link's 15s deadline and fail the page.
        self.assertIn("status == -4", self.search)
        self.assertIn('via = "local-after-stall"', self.search)
        self.assertIn("_diag_append", self.search)

    def test_poll_and_cancel_follow_the_selected_job(self) -> None:
        # Cancel and release must use the same side the job started on: polling
        # a remote id with the local registry reports failure instead of
        # waiting for the app.
        self.assertIn("poll_fn(job_id", self.search)
        self.assertIn("cancel_fn(job_id)", self.search)
        self.assertIn("release_fn(job_id)", self.search)
        self.assertNotIn("_stamp_job_poll_fn(job_id", self.search)


class NomadFetchStampRetryTests(unittest.TestCase):
    """A page fetch retries only when our own key stamp missed the deadline.

    The phone's key-stamp rate makes a 15s deadline miss a multi-percent coin
    flip, and the caller sees it as a plain `link-failed`; a fresh attempt is
    the difference between an occasional popup and none. A node that is simply
    unreachable must not pay for that second attempt.
    """

    def setUp(self):
        self.bridge = load_bridge()
        self.bridge._state["started"] = True
        self.calls = []

    def install(self, statuses, note_failure=True):
        def fake(dest_hash_hex, path, timeout, form_fields):
            self.calls.append(path)
            if note_failure and statuses[len(self.calls) - 1] == "link-failed":
                self.bridge._state["key_stamp_failures"] += 1
            status = statuses[len(self.calls) - 1]
            return {"ok": status == "ok", "status": status, "data": b"page", "content_type": ""}

        self.bridge._fetch_nomadnet_page_once = fake

    def fetch(self):
        return self.bridge.fetch_nomadnet_page("aa" * 16, "/page/index.mu")

    def test_retries_once_after_our_stamp_miss(self):
        self.install(["link-failed", "ok"])
        result = self.fetch()
        self.assertEqual(2, len(self.calls))
        self.assertEqual("ok", result["status"])
        self.assertEqual(b"page", result["data"])

    def test_gives_up_after_one_retry(self):
        self.install(["link-failed", "link-failed"])
        result = self.fetch()
        self.assertEqual(2, len(self.calls))
        self.assertEqual("link-failed", result["status"])

    def test_foreign_link_failure_is_not_retried(self):
        self.install(["link-failed", "ok"], note_failure=False)
        result = self.fetch()
        self.assertEqual(1, len(self.calls))
        self.assertEqual("link-failed", result["status"])

    def test_other_failures_are_not_retried(self):
        for status in ("no-path", "request-failed", "timeout"):
            with self.subTest(status=status):
                self.calls.clear()
                self.install([status, "ok"])
                result = self.fetch()
                self.assertEqual(1, len(self.calls))
                self.assertEqual(status, result["status"])

    def test_not_started_skips_the_attempt(self):
        self.install(["ok"])
        self.bridge._state["started"] = False
        result = self.fetch()
        self.assertEqual([], self.calls)
        self.assertEqual("not-started", result["status"])


if __name__ == "__main__":
    unittest.main()
