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
}
