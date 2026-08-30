#!/usr/bin/env python3
"""Linux-runnable contract checks for the tappable peer map pin (#179).

Guards the wiring that the unit tests (which run on the iOS simulator) and
the Maestro interop flow cannot fully cover on their own:

- MapLibreMapView implements the MapLibre v6.25.1 annotation-selection path
  (didSelectAnnotation / didDeselectAnnotation delegate methods, the
  annotationCanShowCallout callout-suppression hook, the peer_pin_<hash>
  accessibility identifier, and the onPeerTapped / onUserLocationChanged
  callbacks) instead of a custom hit-test.
- MapView presents the PeerContactSheet, wires Directions / Message /
  Remove, and exposes the onOpenPeerChat cross-tab route.
- MainTabView holds the pendingPeerChat state and switches to the Chats tab.
- ChatsView consumes the route via a dedicated `peerConversation` push
  (never the shared notification route, which a concurrent notification
  tap owns) and defers notifications while the route resolves.
- LocationSharingManager implements removePeerLocation and the non-iOS
  Compat.swift stub keeps the API available for cross-platform code.
- Every new Swift file is registered in the hand-maintained pbxproj
  (file ref + build file + group child + a Sources phase entry), because an
  unregistered file compiles into nothing and its tests never run.

The Info.plist LSApplicationQueriesSchemes entry is asserted by
test_host_entitlements_contract.py (the plist contract test).
"""

import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MAP_DIR = REPOSITORY_ROOT / "Sources/ColumbaApp/Views/Map"
MAP_LIBRE_VIEW = MAP_DIR / "MapLibreMapView.swift"
MAP_VIEW = MAP_DIR / "MapView.swift"
PEER_CONTACT_SHEET = MAP_DIR / "PeerContactSheet.swift"
DIRECTIONS_LAUNCHER = MAP_DIR / "DirectionsLauncher.swift"
PEER_LOCATION_FORMATTING = MAP_DIR / "PeerLocationFormatting.swift"
LOCATION_SHARING_MANAGER = (
    REPOSITORY_ROOT / "Sources/ColumbaApp/Services/LocationSharingManager.swift"
)
COMPAT = REPOSITORY_ROOT / "Sources/RNSAPI/Compat.swift"
MAIN_TAB_VIEW = REPOSITORY_ROOT / "Sources/ColumbaApp/Views/MainTabView.swift"
CHATS_VIEW = REPOSITORY_ROOT / "Sources/ColumbaApp/Views/Chats/ChatsView.swift"
PROJECT_FILE = REPOSITORY_ROOT / "Columba.xcodeproj/project.pbxproj"

# (filename, expected Sources-phase targets)
APP_SOURCES = [
    "PeerLocationFormatting.swift",
    "DirectionsLauncher.swift",
    "PeerContactSheet.swift",
]
TEST_SOURCES = [
    "PeerLocationFormattingTests.swift",
    "DirectionsLauncherTests.swift",
    "PeerLocationRemovalTests.swift",
]


class MapPeerPinTapContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.map_libre = MAP_LIBRE_VIEW.read_text(encoding="utf-8")
        cls.map_view = MAP_VIEW.read_text(encoding="utf-8")
        cls.sheet = PEER_CONTACT_SHEET.read_text(encoding="utf-8")
        cls.launcher = DIRECTIONS_LAUNCHER.read_text(encoding="utf-8")
        cls.formatting = PEER_LOCATION_FORMATTING.read_text(encoding="utf-8")
        cls.sharing_manager = LOCATION_SHARING_MANAGER.read_text(encoding="utf-8")
        cls.compat = COMPAT.read_text(encoding="utf-8")
        cls.main_tab = MAIN_TAB_VIEW.read_text(encoding="utf-8")
        cls.chats_view = CHATS_VIEW.read_text(encoding="utf-8")
        cls.project = PROJECT_FILE.read_text(encoding="utf-8")

    # MARK: - MapLibreMapView selection path

    def test_map_view_uses_maplibre_selection_delegates(self):
        # MapLibre v6.25.1: selection is on by default (annotation view
        # enabled flag); the Swift-imported delegate gets a void didSelect /
        # didDeselect pair (the ObjC names drop "Annotation" in Swift).
        # No canSelectAnnotation property exists.
        self.assertIn(
            "func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation)",
            self.map_libre,
        )
        self.assertIn(
            "func mapView(_ mapView: MLNMapView, didDeselect annotation: MLNAnnotation)",
            self.map_libre,
        )
        # The wrong (Mapbox-era) API must not creep back in.
        self.assertNotIn("canSelectAnnotation", self.map_libre)
        # The deprecated selectAnnotation(animated:) form must not be used;
        # the completion-handler variant is the supported one.
        self.assertNotIn("mapView.selectAnnotation(annotation, animated: true)", self.map_libre)

    def test_map_view_suppresses_builtin_callout(self):
        # Only the custom PeerContactSheet is the selection UI, so the
        # built-in callout bubble must be turned off for peer annotations.
        self.assertIn(
            "func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool",
            self.map_libre,
        )
        # Peer annotations must get no callout; other (user) annotations keep
        # the default behavior.
        self.assertRegex(
            self.map_libre,
            r"annotationCanShowCallout[^\n]*\n[^\n]*return annotation is PeerPointAnnotation \? false : true",
        )

    def test_map_view_reports_peer_taps_and_user_location(self):
        # Tap -> onPeerTapped(hash); user blue-dot coordinate ->
        # onUserLocationChanged for the sheet's distance math.
        self.assertIn("var onPeerTapped: ((Data) -> Void)?", self.map_libre)
        self.assertIn(
            "var onUserLocationChanged: ((CLLocationCoordinate2D?) -> Void)?",
            self.map_libre,
        )
        self.assertIn("onPeerTapped?(peerAnnotation.peerHash)", self.map_libre)
        self.assertIn("onUserLocationChanged?(valid)", self.map_libre)

    def test_peer_annotation_carries_hash_keyed_accessibility_id(self):
        # The annotation view is a real UIView, so pins are addressable from
        # XCUITest/Maestro by a stable, hash-keyed identifier. Selection
        # state is keyed on the hash, not the (reused) annotation object.
        self.assertRegex(
            self.map_libre,
            r"accessibilityIdentifier = \"peer_pin_\\\(peerAnnotation.peerHash",
        )

    # MARK: - MapView sheet + routes

    def test_map_view_presents_peer_contact_sheet(self):
        self.assertIn("PeerContactSheet(", self.map_view)
        self.assertIn("peerContactSheet", self.map_view)
        # Sheet is a computed property (the #181 type-checker lesson:
        # inlining a sheet's view tree in body risks a type-check timeout).
        self.assertRegex(self.map_view, r"private var peerContactSheet: some View")

    def test_map_view_wires_sheet_actions(self):
        self.assertIn("onDirections: { launchDirections(for: peer) }", self.map_view)
        # Message: clear the selection, then hand the hash to the cross-tab
        # route.
        self.assertRegex(
            self.map_view,
            r"onMessage: \{[^}]*onOpenPeerChat\?\(hash\)",
            re.DOTALL,
        )
        # Remove: hit the manager, then clear the selection.
        self.assertRegex(
            self.map_view,
            r"onRemove: \{[^}]*removePeerLocation\(peer\.id\)",
            re.DOTALL,
        )

    def test_map_view_routes_message_to_cross_tab_closure(self):
        self.assertIn("var onOpenPeerChat: ((Data) -> Void)? = nil", self.map_view)

    # MARK: - PeerContactSheet a11y identifiers

    def test_sheet_exposes_stable_a11y_identifiers(self):
        for identifier in (
            "peer_sheet_name",
            "peer_sheet_directions",
            "peer_sheet_message",
            "peer_sheet_remove",
        ):
            with self.subTest(identifier=identifier):
                self.assertIn(f'accessibilityIdentifier("{identifier}")', self.sheet)

    def test_sheet_gates_remove_to_stale_peers(self):
        # Android parity: only a stale peer (quiet > 5 min without CEASE)
        # gets the Remove-from-map escape hatch.
        self.assertRegex(
            self.sheet,
            r"if peer\.isStale \{\s*\n\s*Button\(action: onRemove\)",
        )
        self.assertIn('String(localized: "Remove from map")', self.sheet)

    def test_sheet_renders_android_parity_elements(self):
        # 48pt icon dimmed when stale; live "Updated …" line; distance line.
        self.assertIn("size: 48", self.sheet)
        self.assertIn(".opacity(peer.isStale ? 0.6 : 1.0)", self.sheet)
        self.assertIn("String(localized: \"Stale\")", self.sheet)
        self.assertIn(
            "PeerLocationFormatting.formatUpdatedTime(peer.lastUpdate, now: now)",
            self.sheet,
        )
        self.assertIn(
            "PeerLocationFormatting.formatDistanceAndDirection(",
            self.sheet,
        )

    # MARK: - Cross-tab Message route

    def test_main_tab_holds_route_and_switches_tabs(self):
        self.assertIn("@State private var pendingPeerChat: Data? = nil", self.main_tab)
        self.assertIn("ChatsView(", self.main_tab)
        self.assertRegex(
            self.main_tab,
            r"onOpenPeerChat: \{ hash in[^\}]*selectedTab = \.chats[^\}]*pendingPeerChat = hash",
            re.DOTALL,
        )

    def test_chats_view_consumes_route_via_peer_conversation_route(self):
        # A @Binding property CANNOT take `= nil` (the memberwise init
        # parameter is Binding<Data?>, not Data?), so the declaration must
        # have no default.
        self.assertIn("@Binding var pendingPeerChat: Data?\n", self.chats_view)
        self.assertNotIn("@Binding var pendingPeerChat: Data? = nil", self.chats_view)
        self.assertIn("private func consumePeerChatRoute() async", self.chats_view)
        # One-shot: clear before the async work; a route already resolving
        # is never re-entered (double-open guard).
        self.assertRegex(
            self.chats_view,
            r"guard let hash = pendingPeerChat, !isResolvingPeerChat else \{ return \}\s*\n\s*// Clear first.*\n\s*pendingPeerChat = nil",
            re.DOTALL,
        )
        # Telemetry-only peers get a conversation row created, then pushed
        # through the dedicated peer-conversation route.
        self.assertIn(
            "messageRepository.ensureConversation(hash, displayName: nil)",
            self.chats_view,
        )
        # Race fix: the async peer route pushes its OWN destination state,
        # so a notification tap (or vice versa) can never make the last
        # async assignment win a single shared binding.
        self.assertIn("@State private var peerConversation: Conversation?", self.chats_view)
        self.assertIn("@State private var isResolvingPeerChat: Bool = false", self.chats_view)
        self.assertIn(".navigationDestination(item: $peerConversation)", self.chats_view)
        self.assertIn("peerConversation = conversation", self.chats_view)
        # The peer route body must never touch the notification route state.
        route_body = (
            self.chats_view.split("private func consumePeerChatRoute() async")[1]
            .split("\n    // MARK:")[0]
        )
        self.assertNotIn("notificationConversation", route_body)
        # While the route resolves (or after it pushes), a notification tap
        # defers instead of competing for navigation.
        self.assertIn("if isResolvingPeerChat || peerConversation != nil {", self.chats_view)

    # MARK: - Removal + non-iOS stub

    def test_remove_peer_location_drops_entry_and_keeps_stub(self):
        self.assertIn(
            "public func removePeerLocation(_ peerHash: Data) {",
            self.sharing_manager,
        )
        self.assertIn(
            "guard peerLocations.removeValue(forKey: peerHash) != nil else { return }",
            self.sharing_manager,
        )
        # Cross-platform API surface stays available (no-op off-iOS).
        self.assertIn(
            "public func removePeerLocation(_ peerHash: Data) {}",
            self.compat,
        )

    # MARK: - Directions launcher

    def test_directions_launcher_uses_injectable_probe_and_google_scheme(self):
        self.assertIn("protocol SchemeProbe {", self.launcher)
        self.assertIn(
            'static let googleMapsScheme = "comgooglemaps"',
            self.launcher,
        )
        # Apple Maps always first; Google only when the probe says installed.
        self.assertRegex(
            self.launcher,
            r"if probe\.canOpen\(scheme: Self\.googleMapsScheme\) \{",
        )
        # Walking-mode deep link parity with Android.
        self.assertIn(
            "comgooglemaps://?daddr=\\(coordinate.latitude),\\(coordinate.longitude)&directionsmode=walking",
            self.launcher,
        )
        self.assertIn(
            "MKLaunchOptionsDirectionsModeWalking",
            self.launcher,
        )

    # MARK: - Localization keys

    def test_localization_catalog_has_all_new_keys(self):
        catalog_path = (
            REPOSITORY_ROOT / "Sources/ColumbaApp/Resources/Localizable.xcstrings"
        )
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        keys = catalog["strings"]
        for key in (
            "north",
            "northeast",
            "east",
            "southeast",
            "south",
            "southwest",
            "west",
            "northwest",
            "Location unknown",
            "Updated just now",
            "Updated %llds ago",
            "Updated %lldm ago",
            "Updated %lldh ago",
            "Updated %lldd ago",
            "Stale",
            "Directions",
            "Message",
            "Remove from map",
            "Open Directions in:",
            "Apple Maps",
            "Google Maps",
        ):
            with self.subTest(key=key):
                self.assertIn(key, keys)

    # MARK: - pbxproj registration

    def test_new_files_are_registered_in_pbxproj(self):
        # The pbxproj is hand-maintained (objectVersion 60, no folder
        # sync): an unregistered .swift file compiles into nothing and its
        # tests never run. Each new file needs a file ref, a build file per
        # target it belongs to, a group child, and a Sources-phase entry.
        app_filenames = APP_SOURCES
        test_filenames = TEST_SOURCES

        for filename in app_filenames:
            with self.subTest(file=filename):
                # One file reference.
                self.assertRegex(
                    self.project,
                    rf"[A-F0-9]+ /\* {re.escape(filename)} \*/ = \{{isa = PBXFileReference;[^}}]*path = {re.escape(filename)};",
                )
                # Build-file declarations exist (two app targets).
                self.assertRegex(
                    self.project,
                    rf"[A-F0-9]+ /\* {re.escape(filename)} in Sources \*/ = \{{isa = PBXBuildFile;[^}}]*fileRef = [A-F0-9]+ /\* {re.escape(filename)} \*/;",
                )
                # Group child.
                self.assertRegex(
                    self.project,
                    rf"\t[A-F0-9]+ /\* {re.escape(filename)} \*/,",
                )
                # Sources-phase entries (at least the shipping app phase).
                self.assertRegex(
                    self.project,
                    rf"\t[A-F0-9]+ /\* {re.escape(filename)} in Sources \*/,",
                )

        for filename in test_filenames:
            with self.subTest(file=filename):
                self.assertRegex(
                    self.project,
                    rf"[A-F0-9]+ /\* {re.escape(filename)} \*/ = \{{isa = PBXFileReference;[^}}]*path = {re.escape(filename)};",
                )
                self.assertRegex(
                    self.project,
                    rf"[A-F0-9]+ /\* {re.escape(filename)} in Sources \*/ = \{{isa = PBXBuildFile;[^}}]*fileRef = [A-F0-9]+ /\* {re.escape(filename)} \*/;",
                )
                self.assertRegex(
                    self.project,
                    rf"\t[A-F0-9]+ /\* {re.escape(filename)} in Sources \*/,",
                )

    def test_new_files_present_on_disk(self):
        for filename in APP_SOURCES:
            with self.subTest(file=filename):
                self.assertTrue((MAP_DIR / filename).is_file())
        for filename in TEST_SOURCES:
            with self.subTest(file=filename):
                self.assertTrue(
                    (REPOSITORY_ROOT / "Tests/ColumbaAppTests" / filename).is_file()
                )


if __name__ == "__main__":
    unittest.main()
