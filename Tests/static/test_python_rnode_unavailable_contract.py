#!/usr/bin/env python3
"""Contract for truthful Python-runtime RNode startup failure reporting."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
COLUMBA_APP = ROOT / "Sources/ColumbaApp/App/ColumbaApp.swift"


class PythonRNodeUnavailableContractTests(unittest.TestCase):
    def test_python_branch_posts_failed_state_then_throws_dedicated_error(self) -> None:
        source = APP_SERVICES.read_text()
        function = re.search(
            r"public func startRNodeInterface\b.*?"
            r"#elseif COLUMBA_RUNTIME_PYTHON(?P<branch>.*?)#endif",
            source,
            re.DOTALL,
        )
        if function is None:
            self.fail("missing Python branch in startRNodeInterface")
        branch = function.group("branch")
        ordered_fragments = (
            ".connectionFailed(underlying:",
            "self.rnodeInterface = uiInterface",
            "NotificationObserver.postNetworkStateChanged()",
            "throw AppServicesError.rnodeUnavailableInPythonRuntime",
        )
        positions = [branch.find(fragment) for fragment in ordered_fragments]
        self.assertTrue(all(position >= 0 for position in positions), positions)
        self.assertEqual(sorted(positions), positions, "failed UI state must be published before throwing")

    def test_dedicated_error_has_truthful_description(self) -> None:
        source = APP_SERVICES.read_text()
        self.assertRegex(source, r"case rnodeUnavailableInPythonRuntime\b")
        self.assertRegex(
            source,
            r"case \.rnodeUnavailableInPythonRuntime:\s*"
            r"return \"RNode is unavailable in the Python runtime\"",
        )

    def test_startup_caller_logs_success_only_after_throwing_call_returns(self) -> None:
        source = COLUMBA_APP.read_text()
        call = source.index("try await services.startRNodeInterface(")
        success = source.index('DiagLog.log("[STARTUP] RNode started successfully")', call)
        failure = source.index('DiagLog.log("[STARTUP] RNode start FAILED:', success)
        self.assertLess(call, success)
        self.assertLess(success, failure)


if __name__ == "__main__":
    unittest.main()
