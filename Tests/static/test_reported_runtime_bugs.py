#!/usr/bin/env python3
"""Regression contracts for the three runtime bugs reported on 2026-07-19."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
BRIDGE_PY = ROOT / "app/rns_bridge.py"
PYTHON_BRIDGE = ROOT / "Sources/PythonBridge/PythonBridge.swift"
RNS_BACKEND = ROOT / "Sources/RNSAPI/Protocols/RnsBackend.swift"
PY_BACKEND = ROOT / "Sources/RNSBackendPy/PythonRNSBackend.swift"
SWIFT_BACKEND = ROOT / "Sources/RNSBackendSwift/SwiftRNSBackend.swift"
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"
SETTINGS_VIEW = ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"


class ReportedRuntimeBugContracts(unittest.TestCase):
    def test_inbound_event_preserves_canonical_lxmf_hash_end_to_end(self) -> None:
        bridge = BRIDGE_PY.read_text()
        callback = re.search(
            r"def _delivery_callback\(.*?\n(?=\ndef )", bridge, re.DOTALL
        )
        self.assertIsNotNone(callback)
        assert callback is not None
        callback_source = callback.group(0)
        self.assertIn("message_hash", callback_source)
        self.assertRegex(callback_source, r"message\.hash\.hex\(\)")

        py_bridge = PYTHON_BRIDGE.read_text()
        self.assertRegex(
            py_bridge,
            r"case inbound\(sourceHash: String, messageHash: String, content:",
        )
        self.assertIsNotNone(re.search(
            r'case "inbound":.*?key: "message_hash".*?\.inbound\(sourceHash: h, messageHash:',
            py_bridge,
            re.DOTALL,
        ))

        backend_event = RNS_BACKEND.read_text()
        self.assertRegex(
            backend_event,
            r"case inbound\(sourceHash: String, messageHash: String, content:",
        )

        py_backend = PY_BACKEND.read_text()
        self.assertIsNotNone(re.search(
            r"case let \.inbound\(s, mh, c, ti, fh, t\):.*?"
            r"\.inbound\(sourceHash: s, messageHash: mh, content: c",
            py_backend,
            re.DOTALL,
        ))

        swift_backend = SWIFT_BACKEND.read_text()
        self.assertRegex(
            swift_backend,
            r"\.inbound\(sourceHash: message\.sourceHash\.hexHash, "
            r"messageHash: message\.hash\.hexHash, content:",
        )

        app_services = APP_SERVICES.read_text()
        persist = re.search(
            r"private func persistInboundFromPython\b.*?\n    }\n\n    private func handlePythonEvent",
            app_services,
            re.DOTALL,
        )
        self.assertIsNotNone(persist)
        assert persist is not None
        persist_source = persist.group(0)
        self.assertIn("messageHashHex: String", persist_source)
        self.assertIn("Data(hexString: messageHashHex)", persist_source)
        self.assertNotIn("SHA256.hash", persist_source)
        self.assertIsNotNone(re.search(
            r"case \.inbound\(let sourceHash, let messageHash, let content,"
            r".*?persistInboundFromPython\(sourceHash: data, messageHashHex: messageHash,",
            app_services,
            re.DOTALL,
        ))

    def test_rnode_cover_dismissal_clears_editing_state(self) -> None:
        settings = SETTINGS_VIEW.read_text()
        cover = re.search(
            r"\.fullScreenCover\(isPresented: Binding\(.*?\n        \}\n        #endif",
            settings,
            re.DOTALL,
        )
        self.assertIsNotNone(cover)
        assert cover is not None
        self.assertIsNotNone(re.search(
            r"onDismiss:\s*\{.*?interfaceViewModel\?\.dismissConfigSheet\(\).*?\}",
            cover.group(0),
            re.DOTALL,
        ))


if __name__ == "__main__":
    unittest.main()
