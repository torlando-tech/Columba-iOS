import CryptoKit
import XCTest
@testable import ColumbaApp

/// The app answers the NE's link key stamps over an App-Group seam. These tests
/// drive both ends in one process over private queue files, so they never touch
/// the live `key_stamp_*` queues the running app/NE use.
final class KeyStampSeamTests: XCTestCase {
    private var bridge: KeyStampHostBridge!
    private var service: KeyStampHostService!
    private var requestName = ""
    private var responseName = ""

    private let material = Data("seam-material".utf8)
    /// Cost ~4: a handful of attempts, but still an exact-target search.
    private let easyTarget = Data([0x10] + [UInt8](repeating: 0, count: 31))

    override func setUp() {
        super.setUp()
        let suffix = UUID().uuidString
        requestName = "test_key_stamp_n2a_\(suffix)"
        responseName = "test_key_stamp_a2n_\(suffix)"
        bridge = KeyStampHostBridge(requestQueueName: requestName, responseQueueName: responseName)
        service = KeyStampHostService(
            requestQueueName: requestName,
            responseQueueName: responseName,
            label: "test.keyStamp.\(suffix)"
        )
        service.start(disableLocalBridge: false)
    }

    func testServiceAnswersAJobWithAProofForTheTarget() throws {
        let id = bridge.start(material: material, target: easyTarget)
        XCTAssertNotEqual(id, 0, "no accept inside the window")
        defer { bridge.release(id) }

        let answer = try wait(id: id)
        XCTAssertEqual(answer.status, 64)
        XCTAssertEqual(answer.payload.count, 64)
        guard answer.payload.count == 64 else { return }
        XCTAssertTrue(lexicographicallyAtMost(Array(SHA256.hash(data: material + answer.payload[32...])), easyTarget))
    }

    func testCancelTerminatesAJobThatCannotFinish() throws {
        // Only an all-zero digest passes, so the job runs until cancelled.
        let id = bridge.start(material: material, target: Data(repeating: 0, count: 32))
        XCTAssertNotEqual(id, 0)
        defer { bridge.release(id) }
        XCTAssertTrue(bridge.cancel(id))
        let answer = try wait(id: id)
        XCTAssertEqual(answer.status, -2)
    }

    func testNoHostMeansStartReportsUnavailablePromptly() {
        // A second bridge whose queue nobody drains: `start` must give up inside
        // its accept window instead of blocking the page fetch.
        let orphan = KeyStampHostBridge(
            requestQueueName: "test_key_stamp_n2a_orphan_\(UUID().uuidString)",
            responseQueueName: "test_key_stamp_a2n_orphan_\(UUID().uuidString)"
        )
        let started = CFAbsoluteTimeGetCurrent()
        XCTAssertEqual(orphan.start(material: material, target: easyTarget), 0)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 1.0)
    }

    func testUnknownJobPollFailsWithoutBlocking() {
        var out = [Int8](repeating: 0, count: 64)
        var rounds: UInt64 = 0
        let status = out.withUnsafeMutableBufferPointer { buffer in
            bridge.poll(9_999, into: buffer.baseAddress!, capacity: 64, rounds: &rounds)
        }
        XCTAssertEqual(status, -1)
    }

    // MARK: - Helpers

    private struct Answer {
        var status: Int32
        var payload: Data
    }

    private struct TimedOut: Error {}

    private func wait(id: UInt64, timeout: TimeInterval = 10) throws -> Answer {
        var out = [Int8](repeating: 0, count: 64)
        var rounds: UInt64 = 0
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while true {
            let status = out.withUnsafeMutableBufferPointer { buffer in
                bridge.poll(id, into: buffer.baseAddress!, capacity: 64, rounds: &rounds)
            }
            if status < 0 || status == 64 {
                let payload = status > 0
                    ? Data(out.map { UInt8(bitPattern: $0) }.prefix(Int(status)))
                    : Data()
                return Answer(status: status, payload: payload)
            }
            guard CFAbsoluteTimeGetCurrent() < deadline else { throw TimedOut() }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func lexicographicallyAtMost(_ digest: [UInt8], _ target: Data) -> Bool {
        for (left, right) in zip(digest, target) {
            if left != right { return left < right }
        }
        return true
    }
}
