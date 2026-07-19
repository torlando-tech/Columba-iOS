#!/usr/bin/env python3
"""Static ownership and compile-region contract for Python-only declarations."""

import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from test_modelb_caller_guards_contract import unguarded_references


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "Columba.xcodeproj"
PYTHON_FLAG = "COLUMBA_RUNTIME_PYTHON"
PYTHON_ONLY_SOURCES = (
    "Sources/ColumbaApp/Python/Models/PyAnnounce.swift",
    "Sources/ColumbaApp/Python/Models/PyMessage.swift",
    "Sources/ColumbaApp/Python/Models/PyConversation.swift",
    "Sources/ColumbaApp/Python/Models/PyLocalIdentity.swift",
    "Sources/PythonBridge/PythonBridge.swift",
    "Sources/PythonBridge/PythonRuntime.swift",
    "Sources/RNSBackendPy/PythonRNSBackend.swift",
    "Sources/ColumbaApp/Services/PythonNetworkTransport.swift",
    "Sources/PythonBridge/PythonBLECallbackBridge.swift",
)
EXPLICIT_DECLARATIONS = (
    "PythonRuntime",
    "PythonRNSBackend",
    "pythonBackend",
    "PythonBridge",
    "PythonBLECallbackBridge",
    "PythonNetworkTransport",
)
CONFIG_WRITER = "Sources/ColumbaApp/Services/PythonConfigWriter.swift"


def source_membership() -> dict[str, list[str]]:
    ruby = r'''
require 'json'
require 'pathname'
require 'xcodeproj'
project = Xcodeproj::Project.open(ARGV.fetch(0))
root = Pathname.new(File.dirname(ARGV.fetch(0)))
names = %w[ColumbaApp ColumbaModelBApp]
result = names.to_h do |name|
  target = project.targets.find { |candidate| candidate.name == name } or abort "missing #{name}"
  paths = target.source_build_phase.files.map do |file|
    file.file_ref.real_path.relative_path_from(root).to_s
  end
  [name, paths]
end
puts JSON.generate(result)
'''
    result = subprocess.run(
        ["ruby", "-e", ruby, str(PROJECT)], check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return json.loads(result.stdout)


def python_declarations() -> tuple[str, ...]:
    declarations = set(EXPLICIT_DECLARATIONS)
    declaration_pattern = re.compile(
        r"\b(?:actor|class|enum|protocol|struct|typealias)\s+(Py[A-Za-z0-9_]*)\b"
    )
    for relative in PYTHON_ONLY_SOURCES:
        declarations.update(declaration_pattern.findall((ROOT / relative).read_text()))
    return tuple(sorted(declarations))


def model_b_guard_failures(
    membership: dict[str, list[str]], root: Path = ROOT
) -> dict[str, list[tuple[int, str]]]:
    """Scan every compiled Model B source, not merely shipping-shared sources."""
    failures = {}
    declarations = python_declarations()
    model_b_sources = set(membership["ColumbaModelBApp"]) - set(PYTHON_ONLY_SOURCES)
    for relative in sorted(model_b_sources):
        references = unguarded_references(root / relative, declarations, PYTHON_FLAG)
        if references:
            failures[relative] = references
    return failures


class PythonCallerGuardContractTests(unittest.TestCase):
    def references(self, snippet: str) -> list[tuple[int, str]]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Snippet.swift"
            path.write_text(snippet)
            return unguarded_references(path, python_declarations(), PYTHON_FLAG)

    def test_python_only_inventory_is_complete_and_definition_files_are_not_shared(self) -> None:
        inventory = []
        for directory in (
            ROOT / "Sources/PythonBridge",
            ROOT / "Sources/RNSBackendPy",
            ROOT / "Sources/ColumbaApp/Python",
        ):
            inventory.extend(path.relative_to(ROOT).as_posix() for path in directory.rglob("*.swift"))
        inventory.append("Sources/ColumbaApp/Services/PythonNetworkTransport.swift")
        self.assertEqual(set(PYTHON_ONLY_SOURCES), set(inventory))
        self.assertEqual(9, len(PYTHON_ONLY_SOURCES))

        membership = source_membership()
        self.assertTrue(set(PYTHON_ONLY_SOURCES) <= set(membership["ColumbaApp"]))
        self.assertTrue(set(PYTHON_ONLY_SOURCES).isdisjoint(membership["ColumbaModelBApp"]))

    def test_every_model_b_member_source_guards_python_declarations(self) -> None:
        membership = source_membership()
        scanned = set(membership["ColumbaModelBApp"]) - set(PYTHON_ONLY_SOURCES)
        self.assertEqual(set(membership["ColumbaModelBApp"]), scanned)
        self.assertEqual({}, model_b_guard_failures(membership))

    def test_model_b_only_member_mutation_is_scanned_and_positive_guard_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "ModelBOnly.swift"
            membership = {
                "ColumbaApp": [],
                "ColumbaModelBApp": ["ModelBOnly.swift"],
            }

            source.write_text("PythonRuntime.shared.start()\n")
            self.assertEqual(
                {"ModelBOnly.swift": [(1, "PythonRuntime.shared.start()")]},
                model_b_guard_failures(membership, root),
            )

            source.write_text(
                "#if COLUMBA_RUNTIME_PYTHON\n"
                "PythonBridge.shared.stop()\n"
                "#endif\n"
            )
            self.assertEqual({}, model_b_guard_failures(membership, root))

    def test_unguarded_and_non_implying_guards_are_rejected(self) -> None:
        snippet = """PythonRuntime.shared.start()
#if COLUMBA_RUNTIME_PYTHON || os(iOS)
PythonRNSBackend()
#endif
#if !COLUMBA_RUNTIME_PYTHON
let value: PyMessage? = nil
#endif
"""
        self.assertEqual([1, 3, 6], [line for line, _ in self.references(snippet)])

    def test_conjunctive_guard_and_lexical_noise_are_accepted(self) -> None:
        snippet = '''// PythonBridge PythonNetworkTransport
let text = "PythonRuntime PyMessage"
#if COLUMBA_RUNTIME_PYTHON && canImport(Python)
let backend = PythonRNSBackend()
let text = "backend: \\(backend.pythonBackend)"
#endif
'''
        self.assertEqual([], self.references(snippet))

    def test_python_config_writer_is_deliberately_shared_and_cpython_independent(self) -> None:
        membership = source_membership()
        self.assertIn(CONFIG_WRITER, membership["ColumbaApp"])
        self.assertIn(CONFIG_WRITER, membership["ColumbaModelBApp"])
        self.assertNotIn(CONFIG_WRITER, PYTHON_ONLY_SOURCES)

        writer = (ROOT / CONFIG_WRITER).read_text()
        self.assertIn("enum PythonConfigWriter", writer)
        self.assertNotRegex(writer, r"\b(?:PythonRuntime|PythonBridge|PythonRNSBackend|Py[A-Z]\w*|PyObject)\b")
        self.assertNotIn("Python.h", writer)
        self.assertIn("PythonConfigWriter.write", (ROOT / "Sources/ColumbaApp/Services/AppServices.swift").read_text())
        self.assertIn("PythonConfigWriter.sectionName", (ROOT / "Sources/RNSBackendSwift/SwiftRNSBackend.swift").read_text())


if __name__ == "__main__":
    unittest.main()