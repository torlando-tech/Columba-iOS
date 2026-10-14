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
LOCALIZATIONS = ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"
APP_SERVICES = ROOT / "Sources/ColumbaApp/Services/AppServices.swift"


class ContactsNetworkPerformanceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vm = VIEW_MODEL.read_text()
        cls.tab = NETWORK_TAB.read_text()
        cls.identicon = IDENTICON.read_text()
        cls.generator = GENERATOR.read_text()
        cls.view = CONTACTS_VIEW.read_text()
        cls.repository = MESSAGE_REPOSITORY.read_text()
        cls.localizations = LOCALIZATIONS.read_text()
        cls.app_services = APP_SERVICES.read_text()

    def test_path_table_instance_is_reused_across_reinit(self):
        # Regression: the Contacts -> Network tab's live "Show N new" stream
        # broke because AppServices re-inits (identity switch, reconnect,
        # first interface activation) each built a FRESH PathTable and
        # reassigned self.pathTable. ContactsViewModel's
        # `for await entry in pathUpdates` loop had captured the OLD instance
        # at subscription time, so it was pinned to a table that no longer
        # received announces: live updates died (pill never appeared) while
        # pull-to-refresh -- which re-reads appServices.pathTable.allEntries()
        # and gets the NEW instance -- still worked.
        #
        # The fix reuses the existing instance (construct only when nil) at
        # every re-init site. These counts pin that invariant: the three
        # unconditional-reinit sites (both initializeUnlocked overloads and
        # reinitializeConnection) must use the reuse guard, and the ONLY place
        # still allowed to construct a fresh table is initializeBaseStack,
        # which is itself nil-guarded. Re-introducing an unconditional
        # `let newPathTable = try PathTable(...); self.pathTable = newPathTable`
        # anywhere re-breaks the live stream and fails this contract.
        #
        # Reuse guard + rebound instance, one per re-init site:
        self.assertEqual(
            self.app_services.count("if self.pathTable == nil {"), 3,
            "expected exactly the three re-init sites to reuse via the nil guard",
        )
        self.assertEqual(
            self.app_services.count("let newPathTable = self.pathTable!"), 3,
            "expected the three re-init sites to reuse the live instance",
        )
        # Cap the fresh-construct / replace patterns to the single guarded
        # initializeBaseStack site; an unconditional re-init replace makes
        # these exceed 1.
        self.assertLessEqual(
            self.app_services.count("let newPathTable = try PathTable(databasePath: pathDbPath)"),
            1,
            "a re-init site is constructing a fresh PathTable instead of reusing it",
        )
        self.assertLessEqual(
            self.app_services.count("self.pathTable = newPathTable"),
            1,
            "a re-init site is replacing self.pathTable instead of reusing it",
        )

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
        self.assertIn("announceFeedback.hide()", self.vm)
        self.assertIn("resetTask?.cancel()", self.vm)
        self.assertIn("dismiss(ifCurrent: currentGeneration)", self.vm)
        for text in (
            "Announce to Network",
            "Announced",
            "Broadcasts your identity so nearby peers can discover you",
            "Send Announce",
        ):
            self.assertIn(f'"{text}"', self.localizations)

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

    def test_live_reannounce_does_not_rewrite_visible_rows(self):
        # The Network list is a snapshot: it keeps its order and only
        # refreshes on pull-to-refresh / "show new" / tab reload. The
        # #34 regression (live re-sorting the visible list caused mistaps)
        # is why live re-arrangement was removed, and the pending bucket +
        # "N new" chip is the design that lets the list stay put.
        #
        # The live per-announce path (handleNewPathEntry) must therefore
        # NEVER rewrite an already-visible row in place: that in-place
        # write into the 12k @Observable `networkAnnounces` array fires
        # change-tracking and re-renders the list on every re-announce
        # (~all of them on a stable mesh) -- the remaining excess CPU.
        # Genuinely NEW ids still go to `pendingAnnounces`, which is what
        # updates the "N new" chip. Re-introducing a live `networkAnnounces[...]`
        # write inside handleNewPathEntry re-breaks the CPU budget and fails
        # this contract.
        start = self.vm.index("private func handleNewPathEntry(_ entry: PathEntry) {")
        end = self.vm.index("/// Load contacts from storage.", start)
        fn = self.vm[start:end]
        self.assertNotIn(
            "networkAnnounces[",
            fn,
            "the live announce path rewrites a visible row in place; "
            "already-visible ids must be skipped (snapshot stays until refresh)",
        )
        # The already-visible guard short-circuits before the pending bucket.
        self.assertIn("let alreadyVisible = visibleIndex(for: contact.id) != nil", fn)
        # Only new ids buffer into the chip; the bucket is still wired.
        self.assertIn("if !alreadyVisible {", fn)
        self.assertIn("pendingAnnounces.append(contact)", fn)
        self.assertIn("pendingAnnounces.contains(where:", fn)

    def test_structural_network_replacement_invalidates_index(self):
        # The O(1) `visibleIndex(for:)` lookup is backed by a cached
        # id->index map. It is only valid for the generation it was built for,
        # so EVERY structural replacement of `networkAnnounces` (whole-array
        # reassignment -- loadContacts, refreshAnnounces, favorite reconcile)
        # must call `invalidateNetworkIndex()` or the stale cache will drop new
        # peers / report duplicates on the next live lookup. In-place edits of
        # a row (`networkAnnounces[i] = ...` in the user-tap favorite/rename/
        # delete paths) do NOT change the index mapping and are deliberately
        # exempt. Re-introducing a structural `networkAnnounces =` without a
        # following invalidate (before the next replacement) breaks membership
        # and fails this contract.
        text = self.vm
        replace_token = "networkAnnounces = "
        invalidate_token = "invalidateNetworkIndex()"
        sites = [
            m.start()
            for m in re.finditer(re.escape(replace_token), text)
        ]
        self.assertGreaterEqual(
            len(sites),
            3,
            "expected the loadContacts / refreshAnnounces / favorite-reconcile "
            "structural replacements to still exist",
        )
        for i, pos in enumerate(sites):
            upper = sites[i + 1] if i + 1 < len(sites) else len(text)
            segment = text[pos:upper]
            self.assertIn(
                invalidate_token,
                segment,
                "a structural `networkAnnounces =` replacement is not followed "
                "by invalidateNetworkIndex() before the next replacement; the "
                "cached visible index would go stale",
            )


if __name__ == "__main__":
    unittest.main()
