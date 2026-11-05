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

    func testTargetComparisonIsInclusiveAndUnsignedBigEndian() throws {
        let bytes: [UInt8] = [0x00, 0xb5, 0x04, 0xf3, 0x33, 0xc0] + Array(repeating: 0, count: 26)
        let target = try XCTUnwrap(StampTarget(bytes: bytes))
        XCTAssertTrue(target.accepts(bytes))
        var below = bytes
        below[5] -= 1
        below[31] = 0xff
        XCTAssertTrue(target.accepts(below))
        var above = bytes
        above[31] = 1
        XCTAssertFalse(target.accepts(above))
        above = bytes
        above[0] = 1
        above[1] = 0
        XCTAssertFalse(target.accepts(above))
        for index in [8, 16, 24] {
            var laterWord = bytes
            laterWord[index] = 1
            XCTAssertFalse(target.accepts(laterWord))
        }
    }

    func testFractionalTargetJobProducesAnIndependentlyValidProof() throws {
        let workblock = Data("fractional-native-proof".utf8)
        var target = Data([0x00, 0xb5, 0x04, 0xf3, 0x33, 0xc0] + Array(repeating: 0, count: 26))
        let expectedTarget = target
        let jobID = startTargetJob(workblock: workblock, target: target)
        XCTAssertNotEqual(jobID, 0)
        target.resetBytes(in: 0..<target.count)
        defer { XCTAssertEqual(columba_stamp_job_release(jobID), 0) }
        let result = try waitForTerminalStatus(jobID)
        XCTAssertEqual(result.status, 32)
        let digest = Data(SHA256.hash(data: workblock + result.stamp))
        XCTAssertTrue(digest == expectedTarget || digest.lexicographicallyPrecedes(expectedTarget))
    }

    func testMaximumTargetReturnsZeroStamp() throws {
        let jobID = startTargetJob(workblock: Data("any-proof".utf8), target: Data(repeating: 255, count: 32))
        XCTAssertNotEqual(jobID, 0)
        defer { XCTAssertEqual(columba_stamp_job_release(jobID), 0) }
        let result = try waitForTerminalStatus(jobID)
        XCTAssertEqual(result.status, 32)
        XCTAssertEqual(result.stamp, Data(repeating: 0, count: 32))
    }

    func testTargetABIRejectsInvalidAndHarderThanCapTargets() {
        let workblock = Data("invalid-target".utf8)
        for count in [0, 31, 33] {
            XCTAssertEqual(startTargetJob(workblock: workblock, target: Data(repeating: 255, count: count)), 0)
        }
        XCTAssertEqual(startTargetJob(workblock: workblock, target: Data(repeating: 0, count: 32)), 0)
        let harder = Data([0, 0, 0, 0] + Array(repeating: 255, count: 28))
        XCTAssertEqual(startTargetJob(workblock: workblock, target: harder), 0)
        var byte: CChar = 0
        withUnsafePointer(to: &byte) { pointer in
            XCTAssertEqual(columba_stamp_job_start_target(pointer, 1, nil, 32), 0)
            XCTAssertEqual(columba_stamp_job_start_target(nil, 1, pointer, 32), 0)
            XCTAssertEqual(columba_stamp_job_start_target(pointer, -1, pointer, 32), 0)
            XCTAssertEqual(columba_stamp_job_start_target(pointer, 1, pointer, -1), 0)
        }
    }

    func testTargetJobsPreserveCancellationAndRelease() throws {
        let minimum = Data([0, 0, 0, 1] + Array(repeating: 0, count: 28))
        let jobID = startTargetJob(workblock: Data("target-cancel".utf8), target: minimum)
        XCTAssertNotEqual(jobID, 0)
        XCTAssertEqual(columba_stamp_job_cancel(jobID), 0)
        XCTAssertEqual(columba_stamp_job_cancel(jobID), 0)
        XCTAssertEqual(try waitForTerminalStatus(jobID).status, -2)
        XCTAssertEqual(columba_stamp_job_release(jobID), 0)
        XCTAssertEqual(columba_stamp_job_cancel(jobID), -1)
        let released = startTargetJob(workblock: Data("target-release".utf8), target: minimum)
        XCTAssertNotEqual(released, 0)
        XCTAssertEqual(columba_stamp_job_release(released), 0)
        XCTAssertEqual(try waitForTerminalStatus(released).status, -1)
    }

    private func startTargetJob(workblock: Data, target: Data) -> UInt64 {
        workblock.withUnsafeBytes { work in
            target.withUnsafeBytes { bytes in
                columba_stamp_job_start_target(
                    work.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(work.count),
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count)
                )
            }
        }
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
