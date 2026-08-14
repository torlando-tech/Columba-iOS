#!/usr/bin/env python3
"""Regression contract for GitHub issue 160 privacy-card semantics."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SETTINGS_VIEW = ROOT / "Sources/ColumbaApp/Views/Settings/SettingsView.swift"
LOCALIZATIONS = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"


class PrivacySettingsContractTests(unittest.TestCase):
    def setUp(self) -> None:
        source = SETTINGS_VIEW.read_text(encoding="utf-8")
        match = re.search(
            r"private func privacyCard\(_ vm: SettingsViewModel\) -> some View \{"
            r"(?P<body>.*?)\n    \}\n\n    // MARK: - Notifications Card",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        assert match is not None
        self.privacy_card = match.group("body")
        self.catalog = json.loads(LOCALIZATIONS.read_text(encoding="utf-8"))["strings"]

    def test_header_has_no_ambiguous_privacy_toggle(self) -> None:
        header = self.privacy_card.split(") {", 1)[0]
        self.assertNotIn("toggle:", header)

    def test_expanded_content_names_and_explains_the_message_filter(self) -> None:
        self.assertIn(
            'Toggle(String(localized: "Messages from contacts only")',
            self.privacy_card,
        )
        self.assertIn("vm.blockUnknownSenders = newValue", self.privacy_card)
        self.assertIn("vm.saveSettings()", self.privacy_card)

        expected_strings = (
            "Messages from contacts only",
            "Only contacts can message you. Messages from unknown senders are silently discarded.",
            "Anyone can send you messages, including unknown senders.",
        )
        for text in expected_strings:
            self.assertIn(f'String(localized: "{text}")', self.privacy_card)
            self.assertIn(text, self.catalog)
            localization = self.catalog[text]["localizations"]["en"]["stringUnit"]
            self.assertEqual(localization["state"], "translated")
            self.assertEqual(localization["value"], text)


if __name__ == "__main__":
    unittest.main()
