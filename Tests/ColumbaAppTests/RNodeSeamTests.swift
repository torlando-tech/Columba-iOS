import XCTest
@testable import ColumbaModelBApp

/// Unit tests for the Model-B RNode seam: the binary wire codec and the
/// file-backed IPC queue's failure-reporting contract. These exercise REAL
/// production code (the `RNodeSeamMessage` codec in `RNodeSeam.swift` and the
/// `SharedFrameQueue` append/read/return-Bool contract) with no CoreBluetooth
/// and no app-group container, so they're deterministic.
///
/// The RNode radio now runs inside the Network Extension (the in-NE Python
/// `IOSRNodeInterface`), so the app-side `ModelBRNodeService` /
/// `AppGroupRNodeServer` / `AppGroupRNodeSeamTransport` seam files were removed
/// as part of that move. The tests that drove those removed types (restore-
/// identifier contract, empty-name guard, send-timeout watchdog) were dropped
/// with them; the surviving seam surface (codec + frame queue) is what's
/// covered here.
final class RNodeSeamTests: XCTestCase {

    // MARK: - wire codec round-trip (incl. the .stateChanged reason)

    func testWireRoundTrip() throws {
        let cases: [RNodeSeamMessage] = [
            .connect(deviceName: "RNode 9f"),
            .send(reqId: 7, data: Data([0x01, 0x02, 0x03])),
            .disconnect,
            .dataReceived(data: Data([0xC0, 0x00, 0xC0])),
            .stateChanged(state: .connected, reason: nil),
            .stateChanged(state: .failed, reason: "Bluetooth permission denied (check Settings > Privacy > Bluetooth)"),
            .sendResult(reqId: 7, error: nil),
            .sendResult(reqId: 8, error: "write failed"),
        ]
        for msg in cases {
            let decoded = try RNodeSeamMessage(decoding: msg.encode())
            XCTAssertEqual(decoded, msg, "round-trip mismatch for \(msg)")
        }
    }

    // MARK: - SharedFrameQueue round-trip + the Bool return

    func testFrameQueueRoundTripReturnsTrue() {
        // An unentitled group id forces the temp-dir fallback, so this writes a real file.
        let q = SharedFrameQueue(appGroupIdentifier: "group.test.invalid",
                                 name: "rnode-rt-\(UUID().uuidString)")
        XCTAssertTrue(q.append(frame: Data([1, 2, 3]), interfaceTag: 0x21))
        XCTAssertTrue(q.append(frame: Data([4, 5]), interfaceTag: 0x20))
        let frames = q.readAllAndClear()
        XCTAssertEqual(frames.map(\.data), [Data([1, 2, 3]), Data([4, 5])])
        XCTAssertEqual(frames.map(\.interfaceTag), [0x21, 0x20])
        XCTAssertTrue(q.readAllAndClear().isEmpty, "queue should be cleared after read")
    }

    func testFrameQueueAppendReturnsFalseOnWriteFailure() {
        // Pre-create a *directory* at the queue's file path so the write open fails - the
        // exact path the seam wire's drop-detection depends on.
        let name = "rnode-fail-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = SharedFrameQueue(appGroupIdentifier: "group.test.invalid", name: name)
        XCTAssertFalse(q.append(frame: Data([1]), interfaceTag: 0x21))
    }
}
