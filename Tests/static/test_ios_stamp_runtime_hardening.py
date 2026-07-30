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
RNS_SHA = "1c2cf73443ce73613bd67ea8412e7923d34cd7e6"
LXMF_SHA = "fbcb8f83109b93d2491632427716c7fcd645c605"


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
        self.assertIn("*.dist-info/METADATA", self.source)


class NativeStampBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        class Stamper:
            calls = []

            @classmethod
            def set_external_generator(cls, *args, **kwargs):
                cls.calls.append((args, kwargs))

        self.stamper = Stamper
        self.bridge = load_bridge(Stamper)

    def test_token_is_forwarded_and_cancellation_returns_no_stamp(self) -> None:
        class Token:
            def __init__(self):
                self.checks = 0

            def is_cancelled(self):
                self.checks += 1
                return True

        token = Token()
        seen = {}

        def native(workblock, length, cost, output, cancellation, context):
            seen["args"] = (bytes(workblock), length, cost, context)
            seen["cancelled"] = cancellation(context)
            return 0

        self.bridge._stamp_generate_cancellable_fn = native
        self.assertIsNone(self.bridge._native_stamp_pow(b"work", 9, token))
        self.assertEqual((b"work", 4, 9, None), seen["args"])
        self.assertEqual(1, seen["cancelled"])
        self.assertEqual(1, token.checks)

    def test_valid_nonzero_cost_native_proof_path_returns_exact_stamp(self) -> None:
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

        def native(_workblock, _length, native_cost, output, cancellation, context):
            self.assertEqual(cost, native_cost)
            self.assertEqual(0, cancellation(context))
            ctypes.memmove(output, expected, len(expected))
            return len(expected)

        self.bridge._stamp_generate_cancellable_fn = native
        token = types.SimpleNamespace(is_cancelled=lambda: False)
        stamp = self.bridge._native_stamp_pow(workblock, cost, token)
        self.assertEqual(expected, stamp)
        proof = hashlib.sha256(workblock + stamp).digest()
        self.assertGreaterEqual(256 - int.from_bytes(proof, "big").bit_length(), cost)

    def test_install_requests_three_argument_contract_and_forwards_exact_token(self) -> None:
        token = object()
        self.bridge._stamp_generate_cancellable_fn = object()
        self.bridge._native_stamp_pow = mock.Mock(return_value=b"x" * 32)

        self.bridge._install_native_stamp_generator()
        args, kwargs = self.stamper.calls[-1]
        self.assertEqual({"pass_cancellation_token": True}, kwargs)
        self.assertEqual(1, len(args))
        self.assertEqual((b"x" * 32, 0), args[0](b"block", 5, token))
        self.bridge._native_stamp_pow.assert_called_once_with(b"block", 5, token)

    def test_repeated_install_uninstall_does_not_retain_global_callback(self) -> None:
        self.bridge._stamp_generate_cancellable_fn = object()
        for _ in range(2):
            self.bridge._install_native_stamp_generator()
            self.bridge._uninstall_native_stamp_generator()
        self.assertIsNone(self.stamper.calls[-1][0][0])
        self.assertEqual(4, len(self.stamper.calls))

    def test_repeated_stop_when_not_started_still_clears_global_callback(self) -> None:
        self.bridge._stamp_generate_cancellable_fn = object()
        self.bridge._install_native_stamp_generator()
        self.bridge._state["started"] = False
        self.bridge.stop()
        self.bridge.stop()
        self.assertIsNone(self.stamper.calls[-1][0][0])
        self.assertEqual(3, len(self.stamper.calls))


class NativeStampStaticABITests(unittest.TestCase):
    def test_swift_has_cancellable_abi_and_thread_safe_periodic_polling(self) -> None:
        source = STAMP.read_text(encoding="utf-8")
        self.assertIn('@_cdecl("columba_stamp_generate")', source)
        self.assertIn('@_cdecl("columba_stamp_generate_cancellable")', source)
        self.assertIn("isCancelled:", source)
        self.assertRegex(source, r"rounds\s*&\s*0x(?:FF|[1-9A-F][0-9A-F]+)\s*==\s*0")
        self.assertIn("OSAllocatedUnfairLock", source)
        self.assertNotRegex(source, r"nonatomic|UnsafeMutablePointer<Bool>")

    def test_shutdown_paths_unregister_before_taking_bridge_lock(self) -> None:
        source = BRIDGE.read_text(encoding="utf-8")
        for function in ("stop", "reset_identity"):
            body = source[source.index(f"def {function}("):]
            body = body.split("\ndef ", 1)[0]
            self.assertLess(body.index("_uninstall_native_stamp_generator()"), body.index("with _lock:"))


if __name__ == "__main__":
    unittest.main()
