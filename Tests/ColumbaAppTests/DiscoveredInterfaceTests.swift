//
//  DiscoveredInterfaceTests.swift
//  ColumbaApp
//
//  Hosted XCTest coverage for the issue #193 interface-discovery storage
//  seams that the SwiftPM RNSAPITests cannot reach (they run under
//  `-only-testing:ColumbaAppTests`, so they see the app target):
//
//  - the legacy stored-interface Codable path: pre-`bootstrapOnly` JSON must
//    still decode (custom `init(from:)` backfill), and the synthesized
//    `encode(to:)` must keep every original field plus emit the new key —
//    a broken encode would silently lose data on every subsequent save;
//  - the modern stored format round-trips `bootstrapOnly = true` intact.
//  - the discovery settings pending-state model (issue #193 UX fix): the
//    toggle/slider mutate PENDING state only (no persistence, no restart —
//    the old flow restarted Reticulum on every change, and the slider fires
//    on every drag tick, transiently emptying the list and flipping the
//    enabled indicator), the explicit apply intent persists and attempts the
//    in-process restart, and a failed restart keeps the pending flag set for
//    a retry instead of pretending the settings are live.
//
//  NOTE (T-I): the config-writer discovery-key emission
//  (`discover_interfaces`, `autoconnect_discovered_interfaces`,
//  `bootstrap_only`) is deliberately NOT re-asserted here —
//  PythonConfigWriterTests (T-C) already covers it
//  (`testDiscoveryConfigKeysEmitEnabledValues`,
//  `testTcpClientBootstrapOnlyEmitsBootstrapOnlyKey`). The T-H screen a11y
//  identifiers are asserted by the static contract
//  (Tests/static/test_discovered_interfaces_contract.py) instead, since the
//  hosted target has no resource phase to bundle the screen source.
//

import XCTest
import RNSAPI
@testable import ColumbaApp

final class DiscoveredInterfaceTests: XCTestCase {

    // MARK: - Helpers

    /// Old stored format: written before `bootstrapOnly` existed (T-C),
    /// the exact shape InterfaceRepository persisted for pre-release users.
    private static let legacyTcpClientJSON = """
    {
      "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "name": "kin",
      "type": "TCPClient",
      "enabled": true,
      "mode": "full",
      "config": {
        "type": "tcpClient",
        "config": {
          "targetHost": "h",
          "targetPort": 4242,
          "networkName": "n",
          "passphrase": "p"
        }
      },
      "displayOrder": 0,
      "createdAt": 1700000000,
      "updatedAt": 1700000000
    }
    """

    /// Decode the natural storage path: InterfaceEntity ->
    /// InterfaceTypeConfig -> TCPClientConfig.
    private static func decodeLegacy() -> InterfaceEntity {
        try! JSONDecoder().decode(InterfaceEntity.self, from: Data(legacyTcpClientJSON.utf8))
    }

    private static func decodeTCP(_ entity: InterfaceEntity) -> TCPClientConfig {
        guard case .tcpClient(let tcp) = entity.config else {
            fatalError("legacy interface must decode as a tcpClient config, got \(entity.config)")
        }
        return tcp
    }

    // MARK: - legacy decode (bootstrapOnly backfill)

    func testLegacyTcpClientInterfaceJsonDecodesWithBootstrapOnlyBackfilled() {
        let entity = Self.decodeLegacy()

        XCTAssertEqual(entity.name, "kin")
        XCTAssertEqual(entity.type, .tcpClient)

        let tcp = Self.decodeTCP(entity)
        XCTAssertEqual(tcp.targetHost, "h")
        XCTAssertEqual(tcp.targetPort, 4242)
        XCTAssertEqual(tcp.networkName, "n")
        XCTAssertEqual(tcp.passphrase, "p")
        // The custom init(from:) backfill: a missing key must mean `false`,
        // not a keyNotFound decode failure (synthesized Codable would throw
        // here and the whole interface store would fail to load).
        XCTAssertEqual(tcp.bootstrapOnly, false,
                       "a legacy interface without the bootstrapOnly key must decode as bootstrapOnly=false")
    }

    // MARK: - re-encode (synthesized encode(to:) keeps the data)

    func testReencodedLegacyInterfaceEmitsBootstrapOnlyAndKeepsAllFields() {
        let entity = Self.decodeLegacy()
        let reencoded = String(decoding: try! JSONEncoder().encode(entity), as: UTF8.self)

        // The synthesized encode(to:) must emit the backfilled key verbatim.
        XCTAssertTrue(reencoded.contains("\"bootstrapOnly\":false"),
                      "re-encoded legacy interface must emit `\"bootstrapOnly\":false`\\n\\(reencoded)")
        // And keep every original field — losing any of these on a
        // decode-then-save cycle is the data-loss regression this guards.
        for field in ["\"targetHost\":\"h\"", "\"targetPort\":4242",
                      "\"networkName\":\"n\"", "\"passphrase\":\"p\"",
                      "\"id\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\"",
                      "\"name\":\"kin\"", "\"type\":\"TCPClient\"",
                      "\"mode\":\"full\"", "\"enabled\":true"] {
            XCTAssertTrue(reencoded.contains(field),
                          "re-encoded legacy interface must keep \\(field)\\n\\(reencoded)")
        }
    }

    // MARK: - modern round trip

    func testModernInterfaceRoundTripPreservesBootstrapOnlyTrue() {
        let entity = InterfaceEntity(
            name: "kin",
            type: .tcpClient,
            config: .tcpClient(TCPClientConfig(
                targetHost: "rns.kin.earth",
                targetPort: 4242,
                bootstrapOnly: true
            ))
        )

        let json = String(decoding: try! JSONEncoder().encode(entity), as: UTF8.self)
        XCTAssertTrue(json.contains("\"bootstrapOnly\":true"),
                      "a bootstrap interface must store `\"bootstrapOnly\":true`\\n\\(json)")

        let decoded = try! JSONDecoder().decode(InterfaceEntity.self, from: Data(json.utf8))
        let tcp = Self.decodeTCP(decoded)
        XCTAssertEqual(tcp.bootstrapOnly, true,
                       "the modern stored format must round-trip bootstrapOnly=true")
        XCTAssertEqual(tcp.targetHost, "rns.kin.earth")
        XCTAssertEqual(tcp.targetPort, 4242)
    }

    // MARK: - Discovery settings: pending-state model (issue #193 UX)
    //
    // The regression this section locks: the OLD flow persisted + called
    // `restartPythonBackend()` on EVERY toggle/slider change (and the SwiftUI
    // slider fires its setter on every drag tick). Each in-process restart
    // tore the backend down and re-polled it while it was not started, which
    // transiently emptied the discovered-interface list and flipped the
    // "enabled" indicator to off — exactly the "feature appears disabled,
    // then auto re-enables a few seconds later" symptom. The fix makes the
    // toggle + slider pure PENDING state; only `applyDiscoverySettings()`
    // persists and restarts.

    private let kDiscover = "discover_interfaces_enabled"
    private let kAutoconnect = "autoconnect_discovered_count"

    private func resetDiscoverySettings() {
        for store in [UserDefaults(suiteName: appGroupIdentifier), .standard] {
            store?.removeObject(forKey: kDiscover)
            store?.removeObject(forKey: kAutoconnect)
        }
    }

    private func seedDiscovery(enabled: Bool, count: Int) {
        for store in [UserDefaults(suiteName: appGroupIdentifier), .standard] {
            store?.set(enabled, forKey: kDiscover)
            store?.set(count, forKey: kAutoconnect)
        }
    }

    /// Let the VM's init-spawned load task settle.
    ///
    /// NOTE: in the hosted ColumbaAppTests flavor `COLUMBA_RUNTIME_PYTHON` is
    /// defined but no Python backend is ever started, so `loadAsync()` exits
    /// at the `guard let snapshot` (backend nil) BEFORE `loadSettings()`
    /// would run. Tests therefore seed the pending/applied state explicitly
    /// via `await vm.loadSettings()` (public, @MainActor, idempotent) right
    /// after construction — the same seam the real load path uses.
    private func settle(_ ms: UInt64) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// The core regression: moving the auto-connect slider must NOT persist
    /// and must NOT restart Reticulum. The applied/live value and the
    /// persisted value stay put; only the pending value changes.
    @MainActor
    func testSlidingAutoconnectMutatesPendingStateOnlyNoPersistNoRestart() async {
        resetDiscoverySettings()
        defer { resetDiscoverySettings() }
        seedDiscovery(enabled: true, count: 5)

        let vm = DiscoveredInterfacesViewModel(
            appServices: AppServices(),
            settings: SettingsRepository()
        )
        // Seed the pending/applied state (see the settle() note).
        await vm.loadSettings()
        await settle(300)
        XCTAssertFalse(vm.hasPendingDiscoveryChanges, "no change yet → no pending flag")

        // Simulate the user sliding 5 → 3 (the binding calls this on every
        // drag tick; a single call is enough to prove the regression).
        vm.setAutoconnectCount(3)
        await settle(300)

        XCTAssertEqual(vm.autoconnectCount, 3, "the pending value tracks the slider")
        XCTAssertEqual(vm.appliedAutoconnectCount, 5,
                       "the LIVE value must not move until Apply and Restart")
        XCTAssertTrue(vm.hasPendingDiscoveryChanges,
                      "a pending change must be derived so the Apply bar shows")
        XCTAssertFalse(vm.isRestarting,
                       "moving the slider must NOT start a backend restart")
        XCTAssertEqual(vm.isDiscoveryEnabled, false,
                       "the live enabled indicator must not flip while pending")
        // THE regression: the persisted value must still be the applied one
        // (5), not the slider value (3). The old code persisted on every
        // setter call, so this assertion is red against the regression.
        let persisted = SettingsRepository()
        let persistedCount = await persisted.getAutoconnectDiscoveredCount()
        XCTAssertEqual(persistedCount, 5,
                       "the slider must not persist; only Apply does (got \(persistedCount))")
    }

    /// Enabling discovery from off with a never-configured count (the 0
    /// sentinel) defaults the PENDING count to 3 — without persisting and
    /// without restarting (the user still sees the default and can change it
    /// before tapping Apply).
    @MainActor
    func testEnablingDiscoveryDefaultsPendingCountWithoutPersisting() async {
        resetDiscoverySettings()
        defer { resetDiscoverySettings() }
        seedDiscovery(enabled: false, count: 0)

        let vm = DiscoveredInterfacesViewModel(
            appServices: AppServices(),
            settings: SettingsRepository()
        )
        // Seed the pending/applied state (see the settle() note).
        await vm.loadSettings()
        await settle(300)

        vm.setDiscoverInterfacesEnabled(true)
        await settle(300)

        XCTAssertEqual(vm.discoverInterfacesEnabled, true)
        XCTAssertEqual(vm.autoconnectCount, 3, "enabling from off defaults the count to 3")
        XCTAssertTrue(vm.hasPendingDiscoveryChanges)
        XCTAssertFalse(vm.isRestarting)
        let persisted = SettingsRepository()
        let persistedEnabled = await persisted.getDiscoverInterfacesEnabled()
        let persistedCount = await persisted.getAutoconnectDiscoveredCount()
        XCTAssertEqual(persistedEnabled, false, "enabling must not persist until Apply")
        XCTAssertEqual(persistedCount, 0, "the default-3 must be pending only")
    }

    /// Discard reverts the pending values back to the applied (live) state
    /// and clears the pending flag — the settings return to what the running
    /// backend already has.
    @MainActor
    func testDiscardRevertsPendingToAppliedAndClearsFlag() async {
        resetDiscoverySettings()
        defer { resetDiscoverySettings() }
        seedDiscovery(enabled: true, count: 4)

        let vm = DiscoveredInterfacesViewModel(
            appServices: AppServices(),
            settings: SettingsRepository()
        )
        // Seed the pending/applied state (see the settle() note).
        await vm.loadSettings()
        await settle(300)

        vm.setAutoconnectCount(8)
        vm.setDiscoverInterfacesEnabled(false)
        await settle(150)
        XCTAssertTrue(vm.hasPendingDiscoveryChanges)

        vm.discardPendingDiscoveryChanges()
        await settle(150)

        XCTAssertEqual(vm.autoconnectCount, 4)
        XCTAssertEqual(vm.discoverInterfacesEnabled, true)
        XCTAssertFalse(vm.hasPendingDiscoveryChanges, "discard must clear the pending flag")
        XCTAssertFalse(vm.isRestarting)
    }

    /// The explicit apply intent persists the pending values and attempts the
    /// in-process restart. In the hosted ModelB test flavor the Python backend
    /// was never started, so `restartPythonBackend()` returns false — proving
    /// the failure path: the values ARE persisted (for a future real restart)
    /// but the pending flag STAYS set for a retry and an error is surfaced,
    /// instead of pretending the settings are live.
    @MainActor
    func testApplyPersistsValuesAndKeepsPendingFlagWhenRestartFails() async {
        resetDiscoverySettings()
        defer { resetDiscoverySettings() }
        seedDiscovery(enabled: true, count: 5)

        let vm = DiscoveredInterfacesViewModel(
            appServices: AppServices(),
            settings: SettingsRepository()
        )
        // Seed the pending/applied state (see the settle() note).
        await vm.loadSettings()
        await settle(300)
        XCTAssertFalse(vm.hasPendingDiscoveryChanges, "sanity: clean start, no pending")

        vm.setAutoconnectCount(7)
        await settle(150)
        XCTAssertTrue(vm.hasPendingDiscoveryChanges)
        vm.errorMessage = nil

        await vm.applyDiscoverySettings()
        // Poll until the (synchronous) apply work settles: isRestarting back
        // to false and an error surfaced (ModelB restart returns false).
        for _ in 0..<200 where vm.isRestarting || vm.errorMessage == nil {
            await Task.yield()
        }

        let persisted = SettingsRepository()
        let persistedCount = await persisted.getAutoconnectDiscoveredCount()
        XCTAssertEqual(persistedCount, 7,
                       "apply must persist the pending count")
        XCTAssertEqual(vm.appliedAutoconnectCount, 5,
                       "a FAILED restart must not commit the applied snapshot")
        XCTAssertTrue(vm.hasPendingDiscoveryChanges,
                      "a failed apply must keep the pending flag so Apply can be retried")
        XCTAssertNotNil(vm.errorMessage,
                        "a failed restart must surface an error, not silently look applied")
        XCTAssertFalse(vm.isRestarting)
    }

    /// With nothing pending, apply is a no-op guard (no persist, no restart,
    /// no error) — tapping Apply when there is nothing to apply is harmless.
    @MainActor
    func testApplyWithNoPendingChangesIsNoOp() async {
        resetDiscoverySettings()
        defer { resetDiscoverySettings() }
        seedDiscovery(enabled: true, count: 5)

        let vm = DiscoveredInterfacesViewModel(
            appServices: AppServices(),
            settings: SettingsRepository()
        )
        // Seed the pending/applied state (see the settle() note).
        await vm.loadSettings()
        await settle(300)
        XCTAssertFalse(vm.hasPendingDiscoveryChanges)
        vm.errorMessage = nil

        await vm.applyDiscoverySettings()
        await settle(150)

        XCTAssertEqual(vm.appliedAutoconnectCount, 5)
        XCTAssertFalse(vm.hasPendingDiscoveryChanges)
        XCTAssertNil(vm.errorMessage, "no pending changes → apply must not set an error")
        XCTAssertFalse(vm.isRestarting)
    }
}
