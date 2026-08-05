#!/usr/bin/env python3
"""Behavioral regression for NomadNet request-data framing."""

import ast
from pathlib import Path
import sys
import threading
import types
from typing import Any
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "app/rns_bridge.py"


class NomadNetRequestPayloadTests(unittest.TestCase):
    def _load_fetch(self, *, initially_resolved: bool = True):
        tree = ast.parse(BRIDGE.read_text())
        resolve_function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "resolve_path"
        )
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "fetch_nomadnet_page"
        )

        resolution = {"ready": initially_resolved}

        class FakeIdentity:
            @staticmethod
            def recall(_destination_hash):
                return object() if resolution["ready"] else None

        class FakeTransport:
            requests = 0

            @classmethod
            def has_path(cls, _destination_hash):
                return resolution["ready"]

            @classmethod
            def request_path(cls, _destination_hash):
                cls.requests += 1

        class FakeTime:
            now = 0.0

            @classmethod
            def monotonic(cls):
                return cls.now

            @classmethod
            def sleep(cls, seconds):
                cls.now += seconds
                resolution["ready"] = True

        class FakeDestination:
            OUT = 1
            SINGLE = 2

            def __init__(self, *_args):
                pass

        class FakeLink:
            last_request_data = None

            def __init__(self, _destination, established_callback, closed_callback):
                established_callback(self)

            def identify(self, _identity):
                pass

            def request(
                self,
                _path,
                data,
                response_callback,
                failed_callback,
                timeout,
            ):
                del failed_callback, timeout
                type(self).last_request_data = data
                response_callback(types.SimpleNamespace(response=b"ok"))
                return object()

            def teardown(self):
                pass

        fake_rns = types.SimpleNamespace(
            Identity=FakeIdentity,
            Destination=FakeDestination,
            Link=FakeLink,
            Transport=FakeTransport,
        )
        namespace = {
            "Any": Any,
            "RNS": fake_rns,
            "threading": threading,
            "time": FakeTime,
            "_lock": threading.Lock(),
            "_state": {"started": True, "identity": object()},
            "_balanced_runtime_teardown": lambda fn: fn,
        }
        exec(
            compile(
                ast.Module(body=[resolve_function, function], type_ignores=[]),
                str(BRIDGE),
                "exec",
            ),
            namespace,
        )
        return namespace["fetch_nomadnet_page"], FakeLink, FakeTransport

    def test_link_request_receives_mapping_not_prepacked_bytes(self):
        fetch, fake_link, _ = self._load_fetch()
        fake_vendor = types.ModuleType("RNS.vendor")
        setattr(
            fake_vendor,
            "umsgpack",
            types.SimpleNamespace(packb=lambda _value: b"prematurely-packed"),
        )

        with mock.patch.dict(sys.modules, {"RNS.vendor": fake_vendor}):
            result = fetch(
                "35de95d657469cead07d870fa4080573",
                "/page/group.mu",
                form_fields={"var_g": "alephgit_mirrors"},
            )

        self.assertTrue(result["ok"])
        self.assertEqual(
            {"var_g": "alephgit_mirrors"},
            fake_link.last_request_data,
            "RNS.Link.request must receive the request-data map and own MessagePack framing",
        )

    def test_cold_first_fetch_waits_for_requested_path(self):
        fetch, fake_link, fake_transport = self._load_fetch(initially_resolved=False)

        result = fetch(
            "35de95d657469cead07d870fa4080573",
            "/page/index.mu",
            timeout=1.0,
        )

        self.assertTrue(result["ok"], result)
        self.assertEqual("ok", result["status"])
        self.assertEqual(1, fake_transport.requests)
        self.assertIsNone(fake_link.last_request_data)


if __name__ == "__main__":
    unittest.main()
