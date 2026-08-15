#!/usr/bin/env python3
"""Regression contract for cold-start and already-mounted LXMA deep links."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MAIN_TAB = ROOT / "Sources/ColumbaApp/Views/MainTabView.swift"
CONTACTS = ROOT / "Sources/ColumbaApp/Views/Contacts/ContactsView.swift"


class LXMADeepLinkLifecycleTests(unittest.TestCase):
    def test_main_tab_routes_initial_and_late_deep_links_to_contacts(self) -> None:
        source = MAIN_TAB.read_text(encoding="utf-8")

        self.assertIn("routePendingDeepLink()", source)
        self.assertIn("private func routePendingDeepLink()", source)
        self.assertIn("if pendingDeepLink != nil", source)
        self.assertIn("selectedTab = .contacts", source)

        on_appear = source.split(".onAppear {", 1)[1].split("}", 1)[0]
        self.assertIn("routePendingDeepLink()", on_appear)

        on_change = source.split(".onChange(of: pendingDeepLink)", 1)[1].split("}", 2)[0]
        self.assertIn("routePendingDeepLink()", on_change)

    def test_contacts_consumes_initial_and_late_deep_links_idempotently(self) -> None:
        source = CONTACTS.read_text(encoding="utf-8")

        self.assertIn("private func consumePendingDeepLink()", source)
        self.assertIn("pendingDeepLink?.wrappedValue = nil", source)
        self.assertIn("scannedContact = ScannedContact(", source)

        self.assertIn(".onAppear {\n            consumePendingDeepLink()\n        }", source)
        on_change = source.split(".onChange(of: pendingDeepLink?.wrappedValue)", 1)[1].split("}", 2)[0]
        self.assertIn("consumePendingDeepLink()", on_change)


if __name__ == "__main__":
    unittest.main()
