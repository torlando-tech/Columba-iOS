//
//  PeerLocationRemovalTests.swift
//  ColumbaAppTests
//
//  Pins the "Remove from map" contract on LocationSharingManager:
//  removePeerLocation drops the in-memory entry, removal of an unknown
//  hash is a no-op, and a peer that keeps transmitting resurrects its
//  own pin on the next telemetry tick (removal is not a block).
//

#if os(iOS)
import CoreLocation
import XCTest
import LXMFSwift
import RNSAPI
@testable import ColumbaApp

@available(iOS 17.0, *)
@MainActor
final class PeerLocationRemovalTests: XCTestCase {

    private static let peerHash: Data = Data((0...15).map { _ in UInt8(0xAB) })

    /// Encode a valid FIELD_TELEMETRY payload with LXMF-swift's
    /// Sideband-compatible Telemeter codec - the same shape the inbound
    /// decode path in `handleIncomingTelemetry` expects.
    private static func telemetryPayload(
        latitude: Double,
        longitude: Double,
        lastUpdate: Date
    ) -> Data {
        let telemetry = LXMFSwift.LocationTelemetry(
            latitude: latitude,
            longitude: longitude,
            altitude: 0,
            speed: 0,
            bearing: 0,
            accuracy: 5,
            lastUpdate: Int(lastUpdate.timeIntervalSince1970)
        )
        return LXMFSwift.TelemetryPacket(
            timestamp: Int(Date().timeIntervalSince1970),
            location: telemetry
        ).encode()
    }

    private func makeManager() -> LocationSharingManager {
        LocationSharingManager(appServices: AppServices())
    }

    private func receiveTelemetry(
        _ manager: LocationSharingManager,
        latitude: Double = 47.6062,
        longitude: Double = -122.3321,
        displayName: String? = "TestPeer"
    ) {
        manager.handleIncomingTelemetry(
            from: Self.peerHash,
            packet: RNSAPI.TelemetryPacket(payload: Self.telemetryPayload(
                latitude: latitude,
                longitude: longitude,
                lastUpdate: Date()
            )),
            displayName: displayName
        )
    }

    func test_removePeerLocation_drops_the_entry() {
        let manager = makeManager()
        receiveTelemetry(manager)
        XCTAssertNotNil(manager.peerLocations[Self.peerHash])

        manager.removePeerLocation(Self.peerHash)

        XCTAssertNil(manager.peerLocations[Self.peerHash])
    }

    func test_removing_unknown_hash_is_a_no_op() {
        let manager = makeManager()
        receiveTelemetry(manager)
        let otherHash: Data = Data((0...15).map { _ in UInt8(0x01) })

        manager.removePeerLocation(otherHash)

        XCTAssertNotNil(manager.peerLocations[Self.peerHash])
    }

    func test_peer_resurrects_on_next_telemetry_tick_after_removal() {
        // Removal clears the in-memory pin, but a peer that is still
        // transmitting re-announces itself on its next telemetry frame -
        // the same reappear-on-resume behavior as Android. This test
        // documents that contract: removal is not a block.
        let manager = makeManager()
        receiveTelemetry(manager)
        manager.removePeerLocation(Self.peerHash)
        XCTAssertNil(manager.peerLocations[Self.peerHash])

        receiveTelemetry(manager)

        XCTAssertNotNil(manager.peerLocations[Self.peerHash])
    }
}
#endif
