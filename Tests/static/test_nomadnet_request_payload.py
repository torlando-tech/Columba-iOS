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
    def _load_fetch(self):
        tree = ast.parse(BRIDGE.read_text())
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "fetch_nomadnet_page"
        )

        class FakeIdentity:
            @staticmethod
            def recall(_destination_hash):
                return object()

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
            Transport=types.SimpleNamespace(request_path=lambda _hash: None),
        )
        namespace = {
            "Any": Any,
            "RNS": fake_rns,
            "threading": threading,
            "_lock": threading.Lock(),
            "_state": {"started": True, "identity": object()},
            "_balanced_runtime_teardown": lambda fn: fn,
        }
        exec(
            compile(ast.Module(body=[function], type_ignores=[]), str(BRIDGE), "exec"),
            namespace,
        )
        return namespace["fetch_nomadnet_page"], FakeLink

    def test_link_request_receives_mapping_not_prepacked_bytes(self):
        fetch, fake_link = self._load_fetch()
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


if __name__ == "__main__":
    unittest.main()
