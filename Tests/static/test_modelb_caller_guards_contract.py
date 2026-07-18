#!/usr/bin/env python3
"""Static compile-region contract for declarations absent from the Python target."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
CALLERS = (
    ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift",
    ROOT / "Sources/ColumbaApp/Services/AppServices.swift",
    ROOT / "Sources/ColumbaApp/Services/PropagationNodeManager.swift",
)
MODEL_B_DECLARATIONS = (
    "ModelBRNodeService",
    "AppGroupRNodeSeamTransport",
    "AppGroupRNodeSeamWire",
    "AppGroupRNodeServer",
    "RNodeSeamConfig",
    "RNodeLinkState",
    "PropagationSeamConfig",
    "PropagationSyncStateSnapshot",
    "ModelBInboundReplay",
)


def unguarded_references(path: Path) -> list[tuple[int, str]]:
    """Return code references not nested in a positive Model B compile branch."""
    frames: list[bool] = []
    failures: list[tuple[int, str]] = []
    in_block_comment = False
    for number, raw_line in enumerate(path.read_text().splitlines(), 1):
        line = raw_line
        if in_block_comment:
            if "*/" not in line:
                continue
            line = line.split("*/", 1)[1]
            in_block_comment = False
        while "/*" in line:
            before, after = line.split("/*", 1)
            if "*/" in after:
                line = before + after.split("*/", 1)[1]
            else:
                line = before
                in_block_comment = True
                break
        code = line.split("//", 1)[0]
        directive = re.match(r"\s*#(if|elseif|else|endif)\b\s*(.*)", code)
        if directive:
            kind, expression = directive.groups()
            if kind == "if":
                frames.append(expression.strip() == "COLUMBA_RUNTIME_MODEL_B")
            elif kind == "elseif":
                frames[-1] = expression.strip() == "COLUMBA_RUNTIME_MODEL_B"
            elif kind == "else":
                frames[-1] = False
            else:
                frames.pop()
            continue
        if any(token in code for token in MODEL_B_DECLARATIONS) and not any(frames):
            failures.append((number, code.strip()))
    return failures


class ModelBCallerGuardContractTests(unittest.TestCase):
    def test_model_b_declaration_references_are_compile_time_guarded(self) -> None:
        failures = {}
        for path in CALLERS:
            references = unguarded_references(path)
            if references:
                failures[str(path.relative_to(ROOT))] = references
        self.assertEqual({}, failures)

    def test_propagation_manager_has_no_runtime_model_b_selector(self) -> None:
        source = CALLERS[2].read_text()
        self.assertNotIn("BackendPreference.modelB", source)


if __name__ == "__main__":
    unittest.main()