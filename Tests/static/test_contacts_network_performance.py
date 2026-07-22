import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/ContactsViewModel.swift"
NETWORK_TAB = ROOT / "Sources/ColumbaApp/Views/Contacts/NetworkAnnouncesTab.swift"
IDENTICON = ROOT / "Sources/ColumbaApp/Views/Components/Identicon.swift"
GENERATOR = ROOT / "Sources/ColumbaApp/Views/Components/IdenticonGenerator.swift"
CONTACTS_VIEW = ROOT / "Sources/ColumbaApp/Views/Contacts/ContactsView.swift"


class ContactsNetworkPerformanceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vm = VIEW_MODEL.read_text()
        cls.tab = NETWORK_TAB.read_text()
        cls.identicon = IDENTICON.read_text()
        cls.generator = GENERATOR.read_text()
        cls.view = CONTACTS_VIEW.read_text()

    def test_contact_diagnostics_are_aggregate_only(self):
        self.assertNotIn("relayContacts.map", self.vm)
        self.assertNotIn("myContacts.map { \"\\($0.resolvedDisplayName)", self.vm)
        self.assertIn("[CONTACTS] loaded network=", self.vm)
        self.assertIn("relays=", self.vm)

    def test_filtered_network_results_are_stored_not_computed_per_body(self):
        self.assertRegex(
            self.vm,
            r"public private\(set\) var filteredNetworkAnnounces: \[Contact\] = \[\]",
        )
        self.assertIn("rebuildFilteredNetworkAnnounces()", self.vm)
        self.assertIn(
            "public private(set) var filteredPendingAnnounces: [Contact] = []",
            self.vm,
        )
        self.assertIn("rebuildFilteredPendingAnnounces()", self.vm)
        self.assertNotRegex(
            self.vm,
            r"public var filteredNetworkAnnounces: \[Contact\] \{\s*applyAnnounceFilters",
        )

    def test_network_rows_are_incrementally_windowed(self):
        self.assertIn("private static let pageSize = 100", self.tab)
        self.assertIn("@State private var visibleLimit = NetworkAnnouncesTab.pageSize", self.tab)
        self.assertIn("prefix(visibleLimit)", self.tab)
        self.assertIn("loadNextPage", self.tab)
        self.assertIn("visibleLimit = Self.pageSize", self.tab)

    def test_identicon_patterns_are_cached_with_a_bound(self):
        self.assertIn("cachedPattern(from:", self.identicon)
        self.assertIn("patternCache.countLimit = 4096", self.generator)
        self.assertIn("public static func cachedPattern", self.generator)

    def test_contacts_view_does_not_reload_unchanged_data_on_reappearance(self):
        self.assertIn("private var hasLoadedContacts = false", self.vm)
        self.assertIn("public func loadContacts(force: Bool = false)", self.vm)
        self.assertIn("guard force || !hasLoadedContacts else { return }", self.vm)
        self.assertIn("await vm.loadContacts(force: true)", self.view)


if __name__ == "__main__":
    unittest.main()
