import XCTest
@testable import RNSAPI

/// Tests for AppDataParser.displayName + PropagationNodeInfo.parse — the Swift
/// home for LXMF announce app_data interpretation (moved out of the thin Python
/// bridge). app_data is packed here with the production `packMsgPack` so the
/// encoding matches what the device decodes off the wire.
///
/// Lives in the RNSAPI SwiftPM test target (pure Foundation, no app/UIKit/Python
/// deps) so it runs natively via `swift test` — no simulator needed.
///
/// Regression target: lxmf.propagation announces rendered as the display name
/// "False" because index 0 (a legacy boolean) was read as the name regardless
/// of aspect. The name actually lives in the metadata map at index 6.
final class AppDataParserTests: XCTestCase {

    private let pnMetaName: UInt64 = 0x01

    // Mirror LXMF.LXMRouter.get_announce_app_data: [display_name, stamp_cost]
    private func deliveryAppData(name: String?) -> Data {
        let nameVal: MessagePackValue = name.map { .binary(Data($0.utf8)) } ?? .nil
        return packMsgPack(.array([nameVal, .nil]))
    }

    // Mirror LXMF.LXMRouter.get_propagation_node_app_data:
    // [legacy_bool, timebase, node_state, per_transfer, per_sync, stamp_cost, metadata]
    private func propagationAppData(name: String?, nodeState: Bool = true) -> Data {
        var metadata: [MessagePackValue: MessagePackValue] = [:]
        if let name { metadata[.uint(pnMetaName)] = .binary(Data(name.utf8)) }
        return packMsgPack(.array([
            .bool(false),                  // 0: legacy LXMF PN flag
            .uint(1_700_000_000),          // 1: timebase
            .bool(nodeState),              // 2: node state (enabled)
            .uint(50_000),                 // 3: per-transfer limit
            .uint(50_000),                 // 4: per-sync limit
            .array([.uint(0), .uint(0), .uint(0)]), // 5: stamp cost
            .map(metadata),                // 6: metadata (name lives here)
        ]))
    }

    // MARK: - Delivery

    func testDeliveryName() {
        XCTAssertEqual(AppDataParser.displayName(from: deliveryAppData(name: "Alice"), aspect: "lxmf.delivery"), "Alice")
    }

    func testDeliveryUnicode() {
        XCTAssertEqual(AppDataParser.displayName(from: deliveryAppData(name: "Børk 🛰"), aspect: "lxmf.delivery"), "Børk 🛰")
    }

    func testDeliveryNilName() {
        XCTAssertEqual(AppDataParser.displayName(from: deliveryAppData(name: nil), aspect: "lxmf.delivery"), "")
    }

    func testDeliveryLegacyRawUTF8() {
        // Pre-msgpack clients sent the raw name; honored only for non-propagation.
        XCTAssertEqual(AppDataParser.displayName(from: Data("LegacyName".utf8), aspect: "lxmf.delivery"), "LegacyName")
    }

    // MARK: - Propagation (the regression)

    func testPropagationNoNameIsEmptyNotFalse() {
        XCTAssertEqual(AppDataParser.displayName(from: propagationAppData(name: nil), aspect: "lxmf.propagation"), "")
    }

    func testPropagationWithName() {
        XCTAssertEqual(AppDataParser.displayName(from: propagationAppData(name: "RelayOne"), aspect: "lxmf.propagation"), "RelayOne")
    }

    func testPropagationNeverRawUTF8() {
        // Non-msgpack bytes on a propagation aspect must not be read as a name.
        XCTAssertEqual(AppDataParser.displayName(from: Data([0xff, 0xfe, 0x00]), aspect: "lxmf.propagation"), "")
    }

    func testEmptyAppData() {
        XCTAssertEqual(AppDataParser.displayName(from: Data(), aspect: "lxmf.delivery"), "")
        XCTAssertEqual(AppDataParser.displayName(from: Data(), aspect: "lxmf.propagation"), "")
    }

    // MARK: - PropagationNodeInfo.parse

    func testPropagationNodeInfoParse() {
        let info = PropagationNodeInfo.parse(from: propagationAppData(name: "RelayOne", nodeState: true))
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.displayName, "RelayOne")
        XCTAssertEqual(info?.enabled, true)
        XCTAssertEqual(info?.perTransferLimit, 50_000)
        XCTAssertEqual(info?.perSyncLimit, 50_000)
    }

    func testPropagationNodeInfoStateFalse() {
        let info = PropagationNodeInfo.parse(from: propagationAppData(name: nil, nodeState: false))
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.enabled, false)
        XCTAssertNil(info?.displayName)
    }

    func testPropagationNodeInfoRejectsGarbage() {
        XCTAssertNil(PropagationNodeInfo.parse(from: Data([0xff, 0xfe, 0x00])))
        XCTAssertNil(PropagationNodeInfo.parse(from: Data()))
    }
}
