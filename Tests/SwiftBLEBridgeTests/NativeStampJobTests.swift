import CryptoKit
import XCTest
@testable import SwiftBLEBridge

final class NativeStampJobTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = columba_stamp_jobs_cancel_all()
    }

    override func tearDown() {
        _ = columba_stamp_jobs_cancel_all()
        super.tearDown()
    }

    func testZeroCostJobProducesACompleteStamp() throws {
        let jobID = startJob(workblock: Data("workblock".utf8), cost: 0)
        XCTAssertNotEqual(jobID, 0)
        defer { XCTAssertEqual(columba_stamp_job_release(jobID), 0) }

        let result = try waitForTerminalStatus(jobID)
        XCTAssertEqual(result.status, Int32(StampGenerator.stampSize))
        XCTAssertEqual(result.stamp, Data(repeating: 0, count: StampGenerator.stampSize))
    }

    func testNonzeroCostJobProducesAValidProof() throws {
        let workblock = Data("native-stamp-regression".utf8)
        let cost: Int32 = 8
        let jobID = startJob(workblock: workblock, cost: cost)
        XCTAssertNotEqual(jobID, 0)
        defer { XCTAssertEqual(columba_stamp_job_release(jobID), 0) }

        let result = try waitForTerminalStatus(jobID)
        XCTAssertEqual(result.status, Int32(StampGenerator.stampSize))
        XCTAssertEqual(result.stamp.count, StampGenerator.stampSize)
        let digest = SHA256.hash(data: workblock + result.stamp)
        XCTAssertGreaterThanOrEqual(leadingZeroBits(Array(digest)), Int(cost))
    }

    func testCancellationWinsAndRemainsObservableUntilRelease() throws {
        let jobID = startJob(workblock: Data("cancel-me".utf8), cost: 32)
        XCTAssertNotEqual(jobID, 0)

        XCTAssertEqual(columba_stamp_job_cancel(jobID), 0)
        XCTAssertEqual(columba_stamp_job_cancel(jobID), 0)
        let result = try waitForTerminalStatus(jobID)
        XCTAssertEqual(result.status, -2)

        XCTAssertEqual(columba_stamp_job_release(jobID), 0)
        XCTAssertEqual(columba_stamp_job_cancel(jobID), -1)
    }

    func testReleaseCancelsAndDetachesAnActiveJob() {
        let jobID = startJob(workblock: Data("release-me".utf8), cost: 32)
        XCTAssertNotEqual(jobID, 0)
        XCTAssertEqual(columba_stamp_job_release(jobID), 0)

        var output = [CChar](repeating: 0, count: StampGenerator.stampSize)
        let status = output.withUnsafeMutableBufferPointer {
            columba_stamp_job_poll(jobID, $0.baseAddress)
        }
        XCTAssertEqual(status, -1)
        XCTAssertEqual(columba_stamp_job_release(jobID), -1)
    }

    func testCancelledWorkerActuallyStops() {
        let job = NativeStampJob(workblock: Data("stop-worker".utf8), cost: 32)
        job.start()
        job.cancel()
        XCTAssertTrue(job.waitForCompletion(timeout: .now() + 1))
        var output = [CChar](repeating: 0, count: StampGenerator.stampSize)
        let status = output.withUnsafeMutableBufferPointer {
            job.poll(into: $0.baseAddress!)
        }
        XCTAssertEqual(status, -2)
    }

    func testCancelAllDetachesEveryActiveJobWithoutAffectingFutureJobs() throws {
        let first = startJob(workblock: Data("first".utf8), cost: 32)
        let second = startJob(workblock: Data("second".utf8), cost: 32)
        XCTAssertNotEqual(first, 0)
        XCTAssertNotEqual(second, 0)
        XCTAssertEqual(columba_stamp_jobs_cancel_all(), 2)

        var output = [CChar](repeating: 0, count: StampGenerator.stampSize)
        for jobID in [first, second] {
            let status = output.withUnsafeMutableBufferPointer {
                columba_stamp_job_poll(jobID, $0.baseAddress)
            }
            XCTAssertEqual(status, -1)
        }

        let replacement = startJob(workblock: Data("replacement".utf8), cost: 0)
        XCTAssertNotEqual(replacement, 0)
        defer { XCTAssertEqual(columba_stamp_job_release(replacement), 0) }
        XCTAssertEqual(try waitForTerminalStatus(replacement).status, 32)
    }

    func testInvalidCostDoesNotCreateAJob() {
        XCTAssertEqual(startJob(workblock: Data("invalid".utf8), cost: -1), 0)
        XCTAssertEqual(
            startJob(workblock: Data("invalid".utf8), cost: Int32(StampGenerator.maxCost + 1)),
            0
        )
    }

    private func startJob(workblock: Data, cost: Int32) -> UInt64 {
        workblock.withUnsafeBytes { raw in
            columba_stamp_job_start(
                raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                Int32(raw.count),
                cost
            )
        }
    }

    private func waitForTerminalStatus(
        _ jobID: UInt64,
        timeout: TimeInterval = 2
    ) throws -> (status: Int32, stamp: Data) {
        let deadline = Date().addingTimeInterval(timeout)
        var output = [CChar](repeating: 0, count: StampGenerator.stampSize)
        repeat {
            let status = output.withUnsafeMutableBufferPointer {
                columba_stamp_job_poll(jobID, $0.baseAddress)
            }
            if status != 0 {
                return (
                    status,
                    Data(output.map { UInt8(bitPattern: $0) })
                )
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        XCTFail("native stamp job did not reach a terminal state before timeout")
        throw TestError.timeout
    }

    private func leadingZeroBits(_ bytes: [UInt8]) -> Int {
        var count = 0
        for byte in bytes {
            if byte == 0 {
                count += 8
            } else {
                count += byte.leadingZeroBitCount
                break
            }
        }
        return count
    }

    private enum TestError: Error {
        case timeout
    }
}
