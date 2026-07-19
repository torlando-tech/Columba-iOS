#!/usr/bin/env python3
"""Linux-runnable static contract checks for BackendFactory's flavor isolation."""

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FACTORY_SOURCE = REPOSITORY_ROOT / "Sources/ColumbaApp/Services/BackendFactory.swift"


class BackendFactoryContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = FACTORY_SOURCE.read_text(encoding="utf-8")
        cls.python_branch = cls.source.split(
            "#elseif COLUMBA_RUNTIME_PYTHON", maxsplit=1
        )[1].split("#elseif COLUMBA_RUNTIME_MODEL_B", maxsplit=1)[0]
        cls.model_b_branch = cls.source.split(
            "#elseif COLUMBA_RUNTIME_MODEL_B", maxsplit=1
        )[1].split("#else", maxsplit=1)[0]

    def test_factory_enforces_exactly_one_canonical_flavor(self) -> None:
        self.assertIn(
            "#if COLUMBA_RUNTIME_PYTHON && COLUMBA_RUNTIME_MODEL_B", self.source
        )
        self.assertIn(
            '#error("Exactly one Columba runtime flavor may be compiled")',
            self.source,
        )
        self.assertIn(
            '#error("Exactly one Columba runtime flavor must be compiled")',
            self.source,
        )

    def test_shipping_branch_constructs_only_python(self) -> None:
        self.assertIn(
            'DiagLog.log("[BACKEND] active=python flavor=shipping")',
            self.python_branch,
        )
        self.assertIn("return PythonRNSBackend()", self.python_branch)
        self.assertNotIn("ProxyRnsBackend", self.python_branch)
        self.assertNotIn("SwiftRNSBackend", self.python_branch)

    def test_model_b_branch_constructs_only_proxy(self) -> None:
        self.assertIn(
            'DiagLog.log("[BACKEND] active=proxy flavor=modelB")',
            self.model_b_branch,
        )
        self.assertIn("proxySend ?? { _ in nil }", self.model_b_branch)
        self.assertIn("return ProxyRnsBackend(send: send)", self.model_b_branch)
        self.assertNotIn("PythonRNSBackend", self.model_b_branch)
        self.assertNotIn("SwiftRNSBackend", self.model_b_branch)

    def test_factory_does_not_consult_legacy_runtime_preferences(self) -> None:
        make_body = self.source.split("static func make", maxsplit=1)[1]
        self.assertNotIn("BackendPreference", make_body)
        self.assertNotIn("SharedDefaults", make_body)
        self.assertNotIn("useSwiftBackend", make_body)
        self.assertNotIn("SwiftRNSBackend", make_body)


if __name__ == "__main__":
    unittest.main()
