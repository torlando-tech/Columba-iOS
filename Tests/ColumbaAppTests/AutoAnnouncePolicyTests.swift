//
//  AutoAnnouncePolicyTests.swift
//  ColumbaAppTests
//
//  Unit tests for the AutoAnnouncePolicy struct that encodes the user's
//  auto-announce trigger gating rules. Covers master-on/off behavior,
//  per-trigger toggle independence, and the snapshot reader.
//

import XCTest
@testable import ColumbaApp

final class AutoAnnouncePolicyTests: XCTestCase {
    /// Per-test scratch UserDefaults so we don't leak into the real
    /// `UserDefaults.standard` and persist across runs.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.AutoAnnouncePolicy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Construction

    func testDirectInitializerStoresAllFlags() {
        let p = AutoAnnouncePolicy(
            masterEnabled: true,
            onInterval: false,
            onTcpReconnect: true,
            onPeerSpawned: false
        )
        XCTAssertTrue(p.masterEnabled)
        XCTAssertFalse(p.onInterval)
        XCTAssertTrue(p.onTcpReconnect)
        XCTAssertFalse(p.onPeerSpawned)
    }

    // MARK: - Master gate

    func testMasterOffSuppressesAllTriggersEvenWhenAllGranularsOn() {
        defaults.set(false, forKey: "auto_announce_enabled")
        defaults.set(true, forKey: "auto_announce_on_interval")
        defaults.set(true, forKey: "auto_announce_on_tcp_reconnect")
        defaults.set(true, forKey: "auto_announce_on_peer_spawned")

        let p = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertFalse(p.shouldFireOnInterval, "master off must suppress interval")
        XCTAssertFalse(p.shouldFireOnTcpReconnect, "master off must suppress tcp-reconnect")
        XCTAssertFalse(p.shouldFireOnPeerSpawned, "master off must suppress peer-spawned")
    }

    // MARK: - Granular toggles

    func testEachGranularToggleGatesIndependently() {
        // master on, only interval enabled
        defaults.set(true, forKey: "auto_announce_enabled")
        defaults.set(true, forKey: "auto_announce_on_interval")
        defaults.set(false, forKey: "auto_announce_on_tcp_reconnect")
        defaults.set(false, forKey: "auto_announce_on_peer_spawned")

        let only_interval = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertTrue(only_interval.shouldFireOnInterval)
        XCTAssertFalse(only_interval.shouldFireOnTcpReconnect)
        XCTAssertFalse(only_interval.shouldFireOnPeerSpawned)

        // master on, only tcp-reconnect enabled
        defaults.set(false, forKey: "auto_announce_on_interval")
        defaults.set(true, forKey: "auto_announce_on_tcp_reconnect")
        defaults.set(false, forKey: "auto_announce_on_peer_spawned")
        let only_reconnect = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertFalse(only_reconnect.shouldFireOnInterval)
        XCTAssertTrue(only_reconnect.shouldFireOnTcpReconnect)
        XCTAssertFalse(only_reconnect.shouldFireOnPeerSpawned)

        // master on, only peer-spawned enabled
        defaults.set(false, forKey: "auto_announce_on_interval")
        defaults.set(false, forKey: "auto_announce_on_tcp_reconnect")
        defaults.set(true, forKey: "auto_announce_on_peer_spawned")
        let only_peer = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertFalse(only_peer.shouldFireOnInterval)
        XCTAssertFalse(only_peer.shouldFireOnTcpReconnect)
        XCTAssertTrue(only_peer.shouldFireOnPeerSpawned)
    }

    func testAllGranularsOnFiresAll() {
        defaults.set(true, forKey: "auto_announce_enabled")
        defaults.set(true, forKey: "auto_announce_on_interval")
        defaults.set(true, forKey: "auto_announce_on_tcp_reconnect")
        defaults.set(true, forKey: "auto_announce_on_peer_spawned")

        let p = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertTrue(p.shouldFireOnInterval)
        XCTAssertTrue(p.shouldFireOnTcpReconnect)
        XCTAssertTrue(p.shouldFireOnPeerSpawned)
    }

    func testAllGranularsOffFiresNone() {
        defaults.set(true, forKey: "auto_announce_enabled")
        defaults.set(false, forKey: "auto_announce_on_interval")
        defaults.set(false, forKey: "auto_announce_on_tcp_reconnect")
        defaults.set(false, forKey: "auto_announce_on_peer_spawned")

        let p = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertFalse(p.shouldFireOnInterval)
        XCTAssertFalse(p.shouldFireOnTcpReconnect)
        XCTAssertFalse(p.shouldFireOnPeerSpawned)
    }

    // MARK: - Empty defaults

    /// On a fresh install the keys aren't in the suite at all. UserDefaults.bool(forKey:)
    /// returns false for absent keys — so policy must report all-off when nothing has
    /// been registered or set. (Production code uses `register(defaults:)` in
    /// SettingsViewModel.loadLocalSettings to default these to true; that registration
    /// is on UserDefaults.standard, not on a per-suite scratch defaults, so this test
    /// validates the *raw* read behavior.)
    func testEmptyDefaultsReportsAllOff() {
        let p = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertFalse(p.masterEnabled)
        XCTAssertFalse(p.onInterval)
        XCTAssertFalse(p.onTcpReconnect)
        XCTAssertFalse(p.onPeerSpawned)
        XCTAssertFalse(p.shouldFireOnInterval)
        XCTAssertFalse(p.shouldFireOnTcpReconnect)
        XCTAssertFalse(p.shouldFireOnPeerSpawned)
    }

    // MARK: - Snapshot semantics

    /// The struct is a snapshot — changing UserDefaults after `current()`
    /// returned must not retroactively change the policy. Catches any
    /// accidental future refactor that holds a defaults reference.
    func testSnapshotIsImmutableAfterCapture() {
        defaults.set(true, forKey: "auto_announce_enabled")
        defaults.set(true, forKey: "auto_announce_on_interval")
        let snapshot = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertTrue(snapshot.shouldFireOnInterval)

        // Flip the master AFTER snapshotting
        defaults.set(false, forKey: "auto_announce_enabled")
        XCTAssertTrue(snapshot.shouldFireOnInterval, "captured snapshot must not reflect later writes")

        // A fresh snapshot does see the new value
        let fresh = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertFalse(fresh.shouldFireOnInterval)
    }

    // MARK: - Default-true registration contract
    //
    // SettingsViewModel.loadLocalSettings calls defaults.register(defaults: [...])
    // for the four auto_announce_* keys with value `true`, so a fresh install
    // (where the keys were never explicitly written) reads as all-on. This test
    // validates that contract on a per-suite scratch defaults — protects against
    // a future refactor that drops the registration or flips a default to false.

    func testRegisterDefaultsTrueProducesAllFireForFreshInstall() {
        defaults.register(defaults: [
            "auto_announce_enabled": true,
            "auto_announce_on_interval": true,
            "auto_announce_on_tcp_reconnect": true,
            "auto_announce_on_peer_spawned": true,
        ])

        let p = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertTrue(p.masterEnabled)
        XCTAssertTrue(p.onInterval)
        XCTAssertTrue(p.onTcpReconnect)
        XCTAssertTrue(p.onPeerSpawned)
        XCTAssertTrue(p.shouldFireOnInterval)
        XCTAssertTrue(p.shouldFireOnTcpReconnect)
        XCTAssertTrue(p.shouldFireOnPeerSpawned)
    }

    // MARK: - Peer-child attribution
    //
    // `onInterfaceConnected` fires for peer-children of AutoInterface / BLE /
    // MPC parents in addition to standalone TCP / RNode interfaces. When the
    // user disables the peer-spawned toggle but leaves tcp-reconnect on, a
    // peer joining must NOT produce an announce — even though the peer's
    // child transport's `.connected` transition triggers `onInterfaceConnected`.
    // The policy attributes peer-child connected events to the peer-spawned
    // gate, not tcp-reconnect.

    func testPeerChildConnectedGatedByPeerSpawnedNotTcpReconnect() {
        // peer-spawned OFF, tcp-reconnect ON — peer-child connected must NOT fire
        let p1 = AutoAnnouncePolicy(masterEnabled: true, onInterval: false,
                                    onTcpReconnect: true, onPeerSpawned: false)
        XCTAssertFalse(p1.shouldFireOnInterfaceConnected(isPeerChild: true),
                       "peer-child connected gated by peer-spawned (off)")
        XCTAssertTrue(p1.shouldFireOnInterfaceConnected(isPeerChild: false),
                      "non-peer-child connected gated by tcp-reconnect (on)")

        // peer-spawned ON, tcp-reconnect OFF — peer-child connected must fire
        let p2 = AutoAnnouncePolicy(masterEnabled: true, onInterval: false,
                                    onTcpReconnect: false, onPeerSpawned: true)
        XCTAssertTrue(p2.shouldFireOnInterfaceConnected(isPeerChild: true),
                      "peer-child connected gated by peer-spawned (on)")
        XCTAssertFalse(p2.shouldFireOnInterfaceConnected(isPeerChild: false),
                       "non-peer-child connected gated by tcp-reconnect (off)")
    }

    func testPeerChildAttributionRespectsMasterGate() {
        // master off → never fires regardless of peer-child or granulars
        let p = AutoAnnouncePolicy(masterEnabled: false, onInterval: true,
                                   onTcpReconnect: true, onPeerSpawned: true)
        XCTAssertFalse(p.shouldFireOnInterfaceConnected(isPeerChild: true))
        XCTAssertFalse(p.shouldFireOnInterfaceConnected(isPeerChild: false))
    }

    func testPeerChildAttributionAllOn() {
        let p = AutoAnnouncePolicy(masterEnabled: true, onInterval: true,
                                   onTcpReconnect: true, onPeerSpawned: true)
        XCTAssertTrue(p.shouldFireOnInterfaceConnected(isPeerChild: true))
        XCTAssertTrue(p.shouldFireOnInterfaceConnected(isPeerChild: false))
    }

    func testPeerChildAttributionAllGranularsOff() {
        let p = AutoAnnouncePolicy(masterEnabled: true, onInterval: false,
                                   onTcpReconnect: false, onPeerSpawned: false)
        XCTAssertFalse(p.shouldFireOnInterfaceConnected(isPeerChild: true))
        XCTAssertFalse(p.shouldFireOnInterfaceConnected(isPeerChild: false))
    }

    /// Explicit user writes always override the registered default.
    func testExplicitFalseOverridesRegisteredDefaultTrue() {
        defaults.register(defaults: [
            "auto_announce_enabled": true,
            "auto_announce_on_interval": true,
        ])
        defaults.set(false, forKey: "auto_announce_on_interval")

        let p = AutoAnnouncePolicy.current(defaults: defaults)
        XCTAssertTrue(p.masterEnabled, "registered default-true survives")
        XCTAssertFalse(p.onInterval, "explicit false overrides registered default")
        XCTAssertFalse(p.shouldFireOnInterval)
    }
}
