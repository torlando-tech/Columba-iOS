import Foundation
import XCTest
@testable import RNSAPI

/// The Python bridge's `status_json()` carries per-interface announce-rate
/// metrics from RNS `Interface.py`. The UI renders them directly, so a decode
/// regression would either hide the rows or mislabel a quiet interface as a
/// precise zero — lock the wire contract here.
final class StatusSnapshotAnnounceRatesTests: XCTestCase {
    private func decode(_ json: String) throws -> StatusSnapshot {
        try JSONDecoder().decode(StatusSnapshot.self, from: Data(json.utf8))
    }

    func testDecodesAnnounceRateMetricsPerInterface() throws {
        let snapshot = try decode(
            """
            {
              "started": true,
              "interfaces": [
                {
                  "section_name": "Auto_Discovery-1234",
                  "name": "AutoInterface[Auto Discovery]",
                  "online": true,
                  "rx_bytes": 10,
                  "tx_bytes": 20,
                  "is_autoconnect": false,
                  "adopted_count": 2,
                  "incoming_announce_frequency": 0.15,
                  "outgoing_announce_frequency": 2.5,
                  "announce_rate_target": 3600,
                  "held_announces": 3
                }
              ],
              "destination_table_size": 4,
              "path_table_size": 5
            }
            """
        )

        let iface = try XCTUnwrap(snapshot.interfaces.first)
        XCTAssertEqual(iface.incomingAnnounceFrequency, 0.15)
        XCTAssertEqual(iface.outgoingAnnounceFrequency, 2.5)
        XCTAssertEqual(iface.announceRateTarget, 3600)
        XCTAssertEqual(iface.heldAnnounces, 3)
    }

    func testMissingRateKeysDecodeToQuietDefaults() throws {
        // A backend that does not supply the metrics must not break the whole
        // snapshot decode; the fields fall back to zero / nil, which the UI
        // renders as "<0.01 Hz" and omits the optional rows.
        let snapshot = try decode(
            """
            {
              "started": true,
              "interfaces": [
                {
                  "section_name": "Relay",
                  "name": "TCPInterface[hub:4242]",
                  "online": false,
                  "rx_bytes": 0,
                  "tx_bytes": 0
                }
              ]
            }
            """
        )

        let iface = try XCTUnwrap(snapshot.interfaces.first)
        XCTAssertEqual(iface.incomingAnnounceFrequency, 0)
        XCTAssertEqual(iface.outgoingAnnounceFrequency, 0)
        XCTAssertNil(iface.announceRateTarget)
        XCTAssertEqual(iface.heldAnnounces, 0)
    }

    func testNullRateTargetStaysNil() throws {
        let snapshot = try decode(
            """
            {
              "started": true,
              "interfaces": [
                {
                  "section_name": "Relay",
                  "name": "TCPInterface[hub:4242]",
                  "online": true,
                  "rx_bytes": 1,
                  "tx_bytes": 1,
                  "incoming_announce_frequency": 0,
                  "outgoing_announce_frequency": 0,
                  "announce_rate_target": null,
                  "held_announces": 0
                }
              ]
            }
            """
        )

        let iface = try XCTUnwrap(snapshot.interfaces.first)
        XCTAssertNil(iface.announceRateTarget)
    }
}
