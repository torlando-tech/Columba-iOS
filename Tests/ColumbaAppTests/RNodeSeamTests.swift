import XCTest
import ReticulumSwift
@testable import ColumbaModelBApp

/// Unit tests for the Model-B RNode seam: the binary wire codec, the file-backed IPC
/// queue's new failure-reporting contract, the app-side server's empty-name guard, and
/// the NE-side send-timeout watchdog. All exercise REAL production code via an in-memory
/// `RNodeSeamWire` loopback / temp-dir queue — no CoreBluetooth, no SharedFrameQueue
/// app-group container, so they're deterministic.
final class RNodeSeamTests: XCTestCase {

    func testCoreBluetoothRestoreIdentifiersAreUniqueAndMatchRNodeTransport() {
        XCTAssertTrue(ModelBRNodeService.restoreIdentifierContractValid)
    }

    /// In-memory wire: records what's sent, lets the test inject inbound messages.
    final class MockRNodeWire: RNodeSeamWire, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [RNodeSeamMessage] = []
        let inbound: AsyncStream<RNodeSeamMessage>
        private let inboundCont: AsyncStream<RNodeSeamMessage>.Continuation
        init() { (inbound, inboundCont) = AsyncStream.makeStream(of: RNodeSeamMessage.self) }
        func send(_ message: RNodeSeamMessage) { lock.lock(); _sent.append(message); lock.unlock() }
        func start() {}
        func stop() {}
        func inject(_ message: RNodeSeamMessage) { inboundCont.yield(message) }
        var sent: [RNodeSeamMessage] { lock.lock(); defer { lock.unlock() }; return _sent }
    }

    // MARK: - A1: wire codec round-trip (incl. the new .stateChanged reason)

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

    // MARK: - A2: SharedFrameQueue round-trip + the new Bool return

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
        // Pre-create a *directory* at the queue's file path so the write open fails — the
        // exact path the seam wire's drop-detection now depends on.
        let name = "rnode-fail-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = SharedFrameQueue(appGroupIdentifier: "group.test.invalid", name: name)
        XCTAssertFalse(q.append(frame: Data([1]), interfaceTag: 0x21))
    }

    // MARK: - A4: app-side server rejects an empty device name

    func testEmptyDeviceNameRejected() {
        let wire = MockRNodeWire()
        let server = AppGroupRNodeServer(wire: wire)
        server.restoreRadio(deviceName: "")
        XCTAssertEqual(wire.sent, [.stateChanged(state: .failed, reason: "No RNode device selected")],
                       "empty name must surface a failure and never build a radio")
    }

    // MARK: - B4: NE-side send-timeout watchdog

    func testSendTimeoutFailsAndDisconnects() async {
        let wire = MockRNodeWire()
        let transport = AppGroupRNodeSeamTransport(deviceName: "X", wire: wire,
                                                   sendTimeoutNanos: 50_000_000)  // 50ms
        let exp = expectation(description: "send completion fires on timeout")
        var captured: Error?
        transport.send(Data([1, 2, 3])) { err in captured = err; exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        switch captured as? RNodeSeamTransportError {
        case .appWrite: break  // timed-out send
        default: XCTFail("expected appWrite timeout error, got \(String(describing: captured))")
        }
        if case .disconnected = transport.state {} else {
            XCTFail("expected state .disconnected after timeout, got \(transport.state)")
        }
    }

    func testRealSendResultBeforeTimeoutIsNoOp() async {
        let wire = MockRNodeWire()
        let transport = AppGroupRNodeSeamTransport(deviceName: "X", wire: wire,
                                                   sendTimeoutNanos: 5_000_000_000)  // 5s — must NOT fire
        transport.connect()  // starts the inbound task that consumes .sendResult
        let exp = expectation(description: "send completion fires on result")
        var captured: Error? = NSError(domain: "sentinel", code: 1)
        transport.send(Data([1, 2, 3])) { err in captured = err; exp.fulfill() }
        wire.inject(.sendResult(reqId: 0, error: nil))  // first send → reqId 0
        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertNil(captured, "real .sendResult should resolve the send, not the watchdog")
    }
}
