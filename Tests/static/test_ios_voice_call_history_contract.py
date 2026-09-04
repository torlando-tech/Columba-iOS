#!/usr/bin/env python3
"""Contract: iOS Chats Text|Voice subtab (issue #167) wiring + localization."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHATS_VIEW = ROOT / "Sources/ColumbaApp/Views/Chats/ChatsView.swift"
SEGMENT = ROOT / "Sources/ColumbaApp/Views/Chats/ChatsSegmentSelector.swift"
HISTORY = ROOT / "Sources/ColumbaApp/Views/Chats/VoiceHistoryView.swift"
DETAILS = ROOT / "Sources/ColumbaApp/Views/Chats/CallDetailsView.swift"
REPO = ROOT / "Sources/ColumbaApp/Services/CallHistoryRepository.swift"
LOCALIZATIONS = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"
PBX = ROOT / "Columba.xcodeproj/project.pbxproj"


class IOSVoiceCallHistoryContract(unittest.TestCase):
    def setUp(self):
        self.chats = CHATS_VIEW.read_text()
        self.catalog = json.loads(LOCALIZATIONS.read_text())["strings"]
        self.pbx = PBX.read_text()

    def test_segment_selector_present(self):
        self.assertTrue(SEGMENT.exists())
        self.assertIn(".pickerStyle(.segmented)", SEGMENT.read_text())
        self.assertIn("ChatsSegment", self.chats)
        self.assertIn("chats_segment_text", SEGMENT.read_text())
        self.assertIn("chats_segment_voice", SEGMENT.read_text())

    def test_voice_views_present(self):
        self.assertTrue(HISTORY.exists())
        self.assertTrue(DETAILS.exists())
        self.assertIn("call_history_card", HISTORY.read_text())
        self.assertIn("call_history_call_again", DETAILS.read_text())

    def test_voice_search_reachable(self):
        # The Voice segment must expose a search control bound to
        # voiceSearchQuery (previously the query had no UI input).
        self.assertIn("voiceSearchQuery", self.chats)
        self.assertIn("voice_search_toggle", self.chats)
        self.assertIn("voice_search_field", self.chats)
        # The VM must filter the live list by the query (client-side).
        vm = (ROOT / "Sources/ColumbaApp/ViewModels/ChatsViewModel.swift").read_text()
        self.assertIn("filteredVoiceRecords", vm)
        # The list renders the filtered records.
        self.assertIn("filteredVoiceRecords", HISTORY.read_text())

    def test_voice_error_state_surface(self):
        # A failed load must be distinguishable from empty history (P2).
        history = HISTORY.read_text()
        self.assertIn("voiceErrorMessage", history)
        self.assertIn("voice_history_retry", history)

    def test_repository_wired_into_app_services(self):
        app = (ROOT / "Sources/ColumbaApp/Services/AppServices.swift").read_text()
        self.assertIn("callHistoryRepository", app)
        self.assertTrue(REPO.exists())

    def test_shutdown_drains_history_write_chain(self):
        # P1 (iteration 2): AppServices closes the repository right after
        # shutdown() returns, so shutdown must await the ordered write chain
        # first — otherwise a still-pending terminal write is lost.
        cm = (ROOT / "Sources/ColumbaApp/Services/CallManager.swift").read_text()
        shutdown_body = cm[cm.index("func shutdown()"):]
        self.assertIn("historyWriteChain", shutdown_body,
                      "shutdown() must drain the history-write chain before returning")
        self.assertIn("await chain.value", shutdown_body)

    def test_identity_switch_nils_stale_repository(self):
        # P1 (iteration 1): a failed re-open must leave the repository nil,
        # never the previous identity's still-open store.
        app = (ROOT / "Sources/ColumbaApp/Services/AppServices.swift").read_text()
        self.assertIn("if let stale = self.callHistoryRepository", app)
        self.assertIn("self.callHistoryRepository = nil", app)

    def test_new_files_registered_in_pbxproj(self):
        for name in ("ChatsSegmentSelector.swift", "VoiceHistoryView.swift",
                     "CallDetailsView.swift", "CallHistoryRepository.swift",
                     "CallHistoryModels.swift", "CallHistoryFormatting.swift",
                     "CallHistoryFormattingTests.swift", "CallHistoryRepositoryTests.swift"):
            self.assertIn(name, self.pbx, f"{name} missing from project.pbxproj")

    def test_localization_keys_translated(self):
        for key in ("Text", "Voice", "Clear history", "Call again", "Call Details",
                    "Missed", "Declined", "Not connected", "Interrupted", "In progress"):
            entry = self.catalog.get(key)
            self.assertIsNotNone(entry, f"missing catalog key: {key}")
            unit = entry["localizations"]["en"]["stringUnit"]
            self.assertEqual(unit["state"], "translated")
            self.assertEqual(unit["value"], key)


if __name__ == "__main__":
    unittest.main()
