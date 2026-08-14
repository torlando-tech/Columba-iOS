import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VIEW_MODEL = ROOT / "Sources/ColumbaApp/ViewModels/ContactsViewModel.swift"
NETWORK_TAB = ROOT / "Sources/ColumbaApp/Views/Contacts/NetworkAnnouncesTab.swift"
IDENTICON = ROOT / "Sources/ColumbaApp/Views/Components/Identicon.swift"
GENERATOR = ROOT / "Sources/ColumbaApp/Views/Components/IdenticonGenerator.swift"
CONTACTS_VIEW = ROOT / "Sources/ColumbaApp/Views/Contacts/ContactsView.swift"
MESSAGE_REPOSITORY = ROOT / "Sources/ColumbaApp/Services/MessageRepository.swift"


class ContactsNetworkPerformanceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vm = VIEW_MODEL.read_text()
        cls.tab = NETWORK_TAB.read_text()
        cls.identicon = IDENTICON.read_text()
        cls.generator = GENERATOR.read_text()
        cls.view = CONTACTS_VIEW.read_text()
        cls.repository = MESSAGE_REPOSITORY.read_text()

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

    def test_announce_action_explains_itself_and_shows_success_feedback(self):
        self.assertIn('.accessibilityLabel("Announce to Network")', self.view)
        self.assertIn(
            '.accessibilityHint("Broadcasts your identity so nearby peers can discover you")',
            self.view,
        )
        self.assertIn(".safeAreaInset(edge: .top)", self.view)
        self.assertIn("if vm.announceFeedback.isVisible", self.view)
        self.assertIn('Label("Announced", systemImage: "checkmark.circle.fill")', self.view)
        self.assertIn('.accessibilityIdentifier("announce_success_banner")', self.view)
        self.assertIn("UIAccessibility.post(", self.view)
        self.assertIn("notification: .announcement", self.view)
        self.assertIn("public let announceFeedback = AnnounceFeedbackState()", self.vm)
        self.assertIn("resetTask?.cancel()", self.vm)
        self.assertIn("dismiss(ifCurrent: currentGeneration)", self.vm)

    def test_reappearance_refreshes_saved_state_without_rebuilding_paths(self):
        self.assertIn("private var hasLoadedContacts = false", self.vm)
        self.assertIn("public func loadContacts(force: Bool = false)", self.vm)
        self.assertIn("if hasLoadedContacts && !force", self.vm)
        self.assertIn("try await refreshSavedContacts()", self.vm)
        self.assertIn("private func refreshSavedContacts(", self.vm)
        self.assertIn("MessageRepository.favoriteStatusChangedNotification", self.vm)
        self.assertIn("favoriteObserver = NotificationCenter.default.addObserver", self.vm)
        self.assertIn("scheduleSavedContactsRefresh()", self.vm)
        start_listening = self.vm.index("public func startListening()")
        stop_listening = self.vm.index("public func stopListening()", start_listening)
        listener = self.vm[start_listening:stop_listening]
        self.assertLess(
            listener.index("favoriteObserver = NotificationCenter.default.addObserver"),
            listener.index("scheduleSavedContactsRefresh()"),
        )
        self.assertIn("try Task.checkCancellation()", self.vm)
        self.assertIn("private var savedContactsGeneration: UInt64 = 0", self.vm)
        self.assertIn("guard generation == savedContactsGeneration", self.vm)
        self.assertIn("return false", self.vm)
        self.assertGreaterEqual(
            self.vm.count("if let existingIndex = myContacts.firstIndex"), 2
        )
        self.assertIn("favoriteStatusChangedNotification", self.repository)
        self.assertIn("pendingAnnounces = markingSavedContacts", self.vm)
        self.assertIn("isFavorite: saved != nil", self.vm)
        self.assertIn("await vm.loadContacts(force: true)", self.view)


if __name__ == "__main__":
    unittest.main()
