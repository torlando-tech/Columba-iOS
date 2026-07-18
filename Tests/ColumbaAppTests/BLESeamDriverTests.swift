import XCTest
import ReticulumSwift
@testable import ColumbaModelBApp

/// Runtime tests for the NE-side BLE seam proxy (`AppGroupBLEDriver`): that it
/// encodes commands out, feeds the `BLEDriver` streams from decoded app events,
/// and correlates the value-returning calls (`connect`) by `reqId`. Uses an
/// in-memory mock `BLESeamTransport` (no SharedFrameQueue / Darwin), so it's
/// deterministic.
final class BLESeamDriverTests: XCTestCase {

    /// In-memory transport: records what the driver sends, lets the test inject
    /// inbound messages as if they came from the app.
    final class MockSeamTransport: BLESeamTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [BLEDriverSeamMessage] = []
        let inbound: AsyncStream<BLEDriverSeamMessage>
        private let inboundCont: AsyncStream<BLEDriverSeamMessage>.Continuation
        init() { (inbound, inboundCont) = AsyncStream.makeStream(of: BLEDriverSeamMessage.self) }
        func send(_ message: BLEDriverSeamMessage) { lock.lock(); sent.append(message); lock.unlock() }
        func inject(_ message: BLEDriverSeamMessage) { inboundCont.yield(message) }
        var sentMessages: [BLEDriverSeamMessage] { lock.lock(); defer { lock.unlock() }; return sent }
    }

    private func waitUntil(_ timeout: TimeInterval = 2.0, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for condition"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testDiscoveredEventFeedsStream() async throws {
        let mock = MockSeamTransport()
        let driver = AppGroupBLEDriver(transport: mock)
        var it = driver.discoveredPeers.makeAsyncIterator()
        mock.inject(.discovered(address: "peer-A", rssi: -60, identity: nil))
        let peer = await it.next()
        XCTAssertEqual(peer?.address, "peer-A")
        XCTAssertEqual(peer?.rssi, -60)
    }

    func testCommandIsEncodedOut() async throws {
        let mock = MockSeamTransport()
        let driver = AppGroupBLEDriver(transport: mock)
        try await driver.startScanning()
        XCTAssertEqual(mock.sentMessages, [.startScanning])
    }

    func testConnectReqIdRoundTrip() async throws {
        let mock = MockSeamTransport()
        let driver = AppGroupBLEDriver(transport: mock)

        // Start connect concurrently; it sends .connect then awaits the reply.
        async let connection = driver.connect(address: "peerX")

        try await waitUntil { mock.sentMessages.contains { if case .connect = $0 { return true }; return false } }
        guard case let .connect(reqId, address)? = mock.sentMessages.first(where: {
            if case .connect = $0 { return true }; return false
        }) else { return XCTFail("no .connect command sent") }
        XCTAssertEqual(address, "peerX")

        // App replies with the result for that reqId → connect() resumes.
        mock.inject(.connectResult(reqId: reqId, address: "peerX", mtu: 185, identity: nil, error: nil))

        let conn = try await connection
        XCTAssertEqual(conn.address, "peerX")
        XCTAssertEqual(conn.mtu, 185)
    }

    func testConnectErrorPropagates() async throws {
        let mock = MockSeamTransport()
        let driver = AppGroupBLEDriver(transport: mock)
        async let connection = driver.connect(address: "peerY")
        try await waitUntil { mock.sentMessages.contains { if case .connect = $0 { return true }; return false } }
        guard case let .connect(reqId, _)? = mock.sentMessages.first(where: {
            if case .connect = $0 { return true }; return false
        }) else { return XCTFail("no .connect") }
        mock.inject(.connectResult(reqId: reqId, address: "peerY", mtu: 0, identity: nil, error: "timeout"))
        do { _ = try await connection; XCTFail("expected throw") }
        catch let BLESeamError.driver(msg) { XCTAssertEqual(msg, "timeout") }
    }

    func testReceivedFragmentRoutesToConnection() async throws {
        let mock = MockSeamTransport()
        let driver = AppGroupBLEDriver(transport: mock)
        async let connection = driver.connect(address: "p")
        try await waitUntil { mock.sentMessages.contains { if case .connect = $0 { return true }; return false } }
        guard case let .connect(reqId, _)? = mock.sentMessages.first(where: {
            if case .connect = $0 { return true }; return false
        }) else { return XCTFail("no .connect") }
        mock.inject(.connectResult(reqId: reqId, address: "p", mtu: 23, identity: nil, error: nil))
        let conn = try await connection

        var frags = conn.receivedFragments.makeAsyncIterator()
        mock.inject(.receivedFragment(address: "p", data: Data([9, 8, 7])))
        let frag = await frags.next()
        XCTAssertEqual(frag, Data([9, 8, 7]))
    }
}
