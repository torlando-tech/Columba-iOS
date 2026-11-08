import CryptoKit
import XCTest
@testable import SwiftBLEBridge

final class NativeStampJobTests: XCTestCase {
    private let maximumTarget = Data(repeating: 255, count: 32)
    private let minimumTarget = Data(repeating: 0, count: 32)

    override func setUp() {
        super.setUp()
        _ = columba_stamp_jobs_cancel_all()
    }

    override func tearDown() {
        _ = columba_stamp_jobs_cancel_all()
        super.tearDown()
    }

    func testMaximumTargetSupportsGenericCandidateSizes() throws {
        for size in [1, 14, 32, 65] {
            let job = startJob(workblock: Data("any-proof".utf8), target: maximumTarget, size: Int32(size))
            XCTAssertNotEqual(job, 0)
            defer { XCTAssertEqual(columba_stamp_job_release(job), 0) }
            let result = try waitForTerminalStatus(job, capacity: size)
            XCTAssertEqual(result.status, Int32(size))
            XCTAssertEqual(result.stamp.count, size)
            XCTAssertEqual(result.rounds, 0)
        }
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
        let zero = try XCTUnwrap(StampTarget(bytes: Array(repeating: 0, count: 32)))
        XCTAssertTrue(zero.accepts(Array(repeating: 0, count: 32)))
        XCTAssertFalse(zero.accepts(Array(repeating: 0, count: 31) + [1]))
        let smallest = try XCTUnwrap(StampTarget(bytes: Array(repeating: 0, count: 31) + [1]))
        XCTAssertTrue(smallest.accepts(Array(repeating: 0, count: 31) + [1]))
    }

    func testFractionalTargetProducesValidProofForEachCandidateSize() throws {
        let workblock = Data("fractional-native-proof".utf8)
        // RNS's canonical target_from_cost(8.5), from its fixed-point table.
        let expectedTarget = Data([0x00, 0xb5, 0x04, 0xf3, 0x33, 0xc0] + Array(repeating: 0, count: 26))
        for size in [14, 32, 65] {
            var target = expectedTarget
            let job = startJob(workblock: workblock, target: target, size: Int32(size))
            XCTAssertNotEqual(job, 0)
            target.resetBytes(in: 0..<target.count)
            defer { XCTAssertEqual(columba_stamp_job_release(job), 0) }
            let result = try waitForTerminalStatus(job, capacity: size)
            XCTAssertEqual(result.status, Int32(size))
            XCTAssertEqual(result.stamp.count, size)
            let digest = Data(SHA256.hash(data: workblock + result.stamp))
            XCTAssertTrue(digest == expectedTarget || digest.lexicographicallyPrecedes(expectedTarget))
        }
    }

    func testFullTargetRangeIsAcceptedAndCancellationRemainsObservable() throws {
        for target in [minimumTarget, Data([0, 0, 0, 0] + Array(repeating: 255, count: 28))] {
            let job = startJob(workblock: Data("cancel-me".utf8), target: target)
            XCTAssertNotEqual(job, 0)
            XCTAssertEqual(columba_stamp_job_cancel(job), 0)
            XCTAssertEqual(columba_stamp_job_cancel(job), 0)
            XCTAssertEqual(try waitForTerminalStatus(job).status, -2)
            XCTAssertEqual(columba_stamp_job_release(job), 0)
            XCTAssertEqual(columba_stamp_job_cancel(job), -1)
        }
    }

    func testCancelledWorkersPublishRealStableAggregateRounds() throws {
        let job = startJob(workblock: Data("count-cancelled-work".utf8), target: minimumTarget, size: 14)
        XCTAssertNotEqual(job, 0)
        defer { XCTAssertEqual(columba_stamp_job_release(job), 0) }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(columba_stamp_job_cancel(job), 0)
        let result = try waitForTerminalStatus(job, capacity: 14)
        XCTAssertEqual(result.status, -2)
        XCTAssertGreaterThan(result.rounds, 0)
        var output = [CChar](repeating: 17, count: 14)
        var rounds: UInt64 = 0
        let status = output.withUnsafeMutableBufferPointer {
            columba_stamp_job_poll(job, $0.baseAddress, Int32($0.count), &rounds)
        }
        XCTAssertEqual(status, -2)
        XCTAssertEqual(rounds, result.rounds)
        XCTAssertEqual(output, [CChar](repeating: 17, count: 14))
        let completedRounds = rounds
        XCTAssertEqual(columba_stamp_job_cancel(job), 0)
        _ = output.withUnsafeMutableBufferPointer {
            columba_stamp_job_poll(job, $0.baseAddress, Int32($0.count), &rounds)
        }
        XCTAssertEqual(rounds, completedRounds)
    }

    func testLateCancellationWithdrawsCompletedProof() throws {
        let job = startJob(workblock: Data("late-proof".utf8), target: maximumTarget, size: 14)
        defer { XCTAssertEqual(columba_stamp_job_release(job), 0) }
        XCTAssertEqual(try waitForTerminalStatus(job, capacity: 14).status, 14)
        XCTAssertEqual(columba_stamp_job_cancel(job), 0)
        let result = try waitForTerminalStatus(job, capacity: 14)
        XCTAssertEqual(result.status, -2)
        XCTAssertEqual(result.stamp, Data())
        XCTAssertEqual(result.rounds, 0)
    }

    func testOutputCapacityIsCheckedBeforeCopyingAndJobCanBePolledAgain() throws {
        let job = startJob(workblock: Data("buffer-safety".utf8), target: maximumTarget, size: 32)
        defer { XCTAssertEqual(columba_stamp_job_release(job), 0) }
        let completed = try waitForTerminalStatus(job)
        XCTAssertEqual(completed.status, 32)
        var output = [CChar](repeating: 77, count: 40)
        var rounds: UInt64 = 99
        let status = output.withUnsafeMutableBufferPointer {
            columba_stamp_job_poll(job, $0.baseAddress, 31, &rounds)
        }
        XCTAssertEqual(status, -1)
        XCTAssertEqual(output, [CChar](repeating: 77, count: 40))
        XCTAssertEqual(rounds, 0)
        let success = output.withUnsafeMutableBufferPointer {
            columba_stamp_job_poll(job, $0.baseAddress, 32, &rounds)
        }
        XCTAssertEqual(success, 32)
        XCTAssertEqual(Data(output.prefix(32).map { UInt8(bitPattern: $0) }), completed.stamp)
        XCTAssertEqual(Array(output.suffix(8)), [CChar](repeating: 77, count: 8))
    }

    func testInvalidArgumentsDoNotCreateJobsOrCopyOutput() {
        let workblock = Data("invalid".utf8)
        for count in [0, 31, 33] {
            XCTAssertEqual(startJob(workblock: workblock, target: Data(repeating: 255, count: count)), 0)
        }
        for size in [Int32(-1), 0] {
            XCTAssertEqual(startJob(workblock: workblock, target: maximumTarget, size: size), 0)
        }
        var bytes = [CChar](repeating: 0, count: 32)
        bytes.withUnsafeMutableBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            XCTAssertEqual(columba_stamp_job_start(pointer, 1, nil, 32, 14), 0)
            XCTAssertEqual(columba_stamp_job_start(nil, 1, pointer, 32, 14), 0)
            XCTAssertEqual(columba_stamp_job_start(pointer, -1, pointer, 32, 14), 0)
            XCTAssertEqual(columba_stamp_job_start(pointer, 1, pointer, -1, 14), 0)
            var rounds: UInt64 = 0
            XCTAssertEqual(columba_stamp_job_poll(0, pointer, 32, &rounds), -1)
            XCTAssertEqual(columba_stamp_job_poll(1, nil, 32, &rounds), -1)
            XCTAssertEqual(columba_stamp_job_poll(1, pointer, -1, &rounds), -1)
            XCTAssertEqual(columba_stamp_job_poll(1, pointer, 32, nil), -1)
        }
    }

    func testReleaseCancelsAndDetachesAnActiveJob() throws {
        let job = startJob(workblock: Data("release-me".utf8), target: minimumTarget)
        XCTAssertNotEqual(job, 0)
        XCTAssertEqual(columba_stamp_job_release(job), 0)
        XCTAssertEqual(try waitForTerminalStatus(job).status, -1)
        XCTAssertEqual(columba_stamp_job_release(job), -1)
    }

    func testCancelAllDetachesJobsWithoutAffectingFutureJobs() throws {
        let first = startJob(workblock: Data("first".utf8), target: minimumTarget)
        let second = startJob(workblock: Data("second".utf8), target: minimumTarget)
        XCTAssertNotEqual(first, 0)
        XCTAssertNotEqual(second, 0)
        XCTAssertEqual(columba_stamp_jobs_cancel_all(), 2)
        for job in [first, second] {
            XCTAssertEqual(try waitForTerminalStatus(job).status, -1)
        }
        let replacement = startJob(workblock: Data("replacement".utf8), target: maximumTarget)
        defer { XCTAssertEqual(columba_stamp_job_release(replacement), 0) }
        XCTAssertEqual(try waitForTerminalStatus(replacement).status, 32)
    }

    func testPreCancelledSearchDoesNoWork() throws {
        let cancellation = StampCancellationState()
        cancellation.cancel()
        let result = StampGenerator.search(
            workblock: Data("pre-cancelled".utf8),
            target: try XCTUnwrap(StampTarget(bytes: Array(maximumTarget))),
            size: 14, cancellation: cancellation
        )
        XCTAssertNil(result.stamp)
        XCTAssertEqual(result.rounds, 0)
    }

    private func startJob(workblock: Data, target: Data, size: Int32 = 32) -> UInt64 {
        workblock.withUnsafeBytes { work in
            target.withUnsafeBytes { bytes in
                columba_stamp_job_start(
                    work.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(work.count),
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), size
                )
            }
        }
    }

    private func waitForTerminalStatus(
        _ job: UInt64, capacity: Int = 32, timeout: TimeInterval = 2
    ) throws -> (status: Int32, stamp: Data, rounds: UInt64) {
        let deadline = Date().addingTimeInterval(timeout)
        var output = [CChar](repeating: 0, count: capacity)
        var rounds: UInt64 = 0
        repeat {
            let status = output.withUnsafeMutableBufferPointer {
                columba_stamp_job_poll(job, $0.baseAddress, Int32($0.count), &rounds)
            }
            if status != 0 {
                return (status, Data(output.prefix(max(0, Int(status))).map { UInt8(bitPattern: $0) }), rounds)
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        XCTFail("native stamp job did not reach a terminal state before timeout")
        throw TestError.timeout
    }

    private enum TestError: Error {
        case timeout
    }
}
