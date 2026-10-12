import XCTest
@testable import ColumbaApp

/// Tests for the Model B BLE seam wire (`BLEDriverSeamMessage`) + the BLE
/// interface gate. The wire is the foundation of the cross-process radio
/// bridge: the NE's Python driver issues `columba_ble_*` commands that the NE
/// forwarder encodes app-bound, and the app's `SwiftBLEBridge` events are
/// decoded NE-bound. These tests prove every case survives an encode/decode
/// round trip (bit-for-bit) so the two processes can't drift apart.
final class BLESeamDriverTests: XCTestCase {

    // MARK: - Wire round-trip

    private func assertRoundTrip(_ message: BLEDriverSeamMessage) {
        let data = message.encode()
        let decoded = try! BLEDriverSeamMessage(decoding: data)
        XCTAssertEqual(decoded, message, "round-trip mismatch for \(message)")
    }

    func testCommandCasesRoundTrip() throws {
        assertRoundTrip(.start(serviceUuid: "37145b00-442d-4a94-917f-8f42c5da28e3",
                               rxCharUuid: "37145b00-442d-4a94-917f-8f42c5da28e5",
                               txCharUuid: "37145b00-442d-4a94-917f-8f42c5da28e4",
                               identityCharUuid: "37145b00-442d-4a94-917f-8f42c5da28e6"))
        assertRoundTrip(.stop)
        assertRoundTrip(.setIdentity(identity: Data([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15])))
        assertRoundTrip(.startScanning)
        assertRoundTrip(.stopScanning)
        assertRoundTrip(.startAdvertising(deviceName: "Columba-TEST", identity: Data(repeating: 7, count: 16)))
        assertRoundTrip(.startAdvertising(deviceName: "", identity: Data()))
        assertRoundTrip(.stopAdvertising)
        assertRoundTrip(.connect(address: "AAAA-BBBB"))
        assertRoundTrip(.disconnect(address: "AAAA-BBBB"))
        assertRoundTrip(.send(address: "AAAA-BBBB", data: Data([0xDE, 0xAD, 0xBE, 0xEF])))
        assertRoundTrip(.send(address: "AAAA-BBBB", data: Data()))
        assertRoundTrip(.syncExistingConnections)
        assertRoundTrip(.requestIdentityResync(address: "AAAA-BBBB"))
        assertRoundTrip(.configurePower(address: "", txPowerDbm: 0))
    }

    func testEventCasesRoundTrip() throws {
        assertRoundTrip(.deviceDiscovered(address: "peer-A", name: "AndroidPhone", rssi: -60))
        assertRoundTrip(.deviceDiscovered(address: "peer-A", name: "", rssi: Int16.min))
        assertRoundTrip(.deviceConnected(address: "peer-A", peerIdentity: Data(repeating: 1, count: 16)))
        assertRoundTrip(.deviceConnected(address: "peer-A", peerIdentity: nil))
        assertRoundTrip(.deviceDisconnected(address: "peer-A"))
        assertRoundTrip(.dataReceived(address: "peer-A", data: Data([9, 8, 7])))
        assertRoundTrip(.dataReceived(address: "peer-A", data: Data()))
        assertRoundTrip(.mtuNegotiated(address: "peer-A", mtu: 185))
        assertRoundTrip(.mtuNegotiated(address: "peer-A", mtu: 0))
        assertRoundTrip(.identityReceived(address: "peer-A", identityHex: "00112233445566778899aabbccddeeff"))
        assertRoundTrip(.identityReceived(address: "peer-A", identityHex: ""))
        assertRoundTrip(.addressChanged(old: "old-addr", new: "new-addr", identityHash: "00112233445566778899aabbccddeeff"))
        assertRoundTrip(.error(severity: "error", message: "Bluetooth power off"))
        assertRoundTrip(.error(severity: "info", message: ""))
    }

    /// Distinct messages must not collide to the same encoding (tag confusion
    /// would silently mis-deliver commands across the process boundary).
    func testDistinctMessagesHaveDistinctEncodings() {
        let samples: [BLEDriverSeamMessage] = [
            .stop, .stopScanning, .stopAdvertising, .syncExistingConnections,
            .startScanning, .deviceDisconnected(address: "a"), .connect(address: "a"),
        ]
        let encodings = Set(samples.map { $0.encode() })
        XCTAssertEqual(encodings.count, samples.count, "two distinct messages encoded identically")
    }

}
