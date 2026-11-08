// Native multi-core hash search for RNS.Stamps. RNS owns workblock derivation,
// targets, validation and cancellation; Python polls these signed C entry points.

import Foundation
import CommonCrypto
import os

/// An inclusive unsigned 256-bit threshold in network byte order.
struct StampTarget: Sendable {
    private let a: UInt64
    private let b: UInt64
    private let c: UInt64
    private let d: UInt64

    init?(bytes: [UInt8]) {
        guard let target = bytes.withUnsafeBytes({ Self(bytes: $0) }) else { return nil }
        self = target
    }

    init?(bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 32 else { return nil }
        a = Self.word(bytes, at: 0)
        b = Self.word(bytes, at: 8)
        c = Self.word(bytes, at: 16)
        d = Self.word(bytes, at: 24)
    }

    var acceptsEveryDigest: Bool {
        a == .max && b == .max && c == .max && d == .max
    }

    @inline(__always)
    private static func word(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always)
    func accepts(_ digest: [UInt8]) -> Bool {
        digest.withUnsafeBytes { bytes in
            let first = Self.word(bytes, at: 0)
            if first != a { return first < a }
            let second = Self.word(bytes, at: 8)
            if second != b { return second < b }
            let third = Self.word(bytes, at: 16)
            if third != c { return third < c }
            return Self.word(bytes, at: 24) <= d
        }
    }
}

struct StampSearchResult {
    let stamp: Data?
    let rounds: UInt64
}

enum StampGenerator {
    static func search(
        workblock: Data,
        target: StampTarget,
        size: Int,
        cancellation: StampCancellationState = StampCancellationState()
    ) -> StampSearchResult {
        guard size > 0, size <= Int32.max, !cancellation.isCancelled else {
            return StampSearchResult(stamp: nil, rounds: 0)
        }
        if target.acceptsEveryDigest {
            return StampSearchResult(stamp: Data(repeating: 0, count: size), rounds: 0)
        }

        // CC_SHA256_CTX is a flat value. Absorb the prefix once, then copy its
        // midstate for each candidate rather than hashing the workblock again.
        var base = CC_SHA256_CTX()
        CC_SHA256_Init(&base)
        workblock.withUnsafeBytes { raw in
            if let pointer = raw.baseAddress, raw.count > 0 {
                CC_SHA256_Update(&base, pointer, CC_LONG(raw.count))
            }
        }

        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let result = StampResultBox()
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var candidate = [UInt8](repeating: 0, count: size)
            var rng = SystemRandomNumberGenerator()
            for i in candidate.indices { candidate[i] = UInt8.random(in: 0...255, using: &rng) }
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            var rounds: UInt64 = 0
            var found = false
            // Each worker publishes its failed-attempt count exactly once.
            defer {
                result.finishWorker(stamp: found ? candidate : nil, rounds: rounds, cancellation: cancellation)
            }
            if result.shouldStop(cancellation: cancellation) { return }

            while true {
                var ctx = base
                _ = candidate.withUnsafeBufferPointer { CC_SHA256_Update(&ctx, $0.baseAddress, CC_LONG(size)) }
                CC_SHA256_Final(&digest, &ctx)
                if target.accepts(digest) {
                    found = true
                    return
                }
                rounds &+= 1

                var index = size - 1
                while index >= 0 {
                    candidate[index] &+= 1
                    if candidate[index] != 0 { break }
                    index -= 1
                }
                if rounds & 0x3F == 0, result.shouldStop(cancellation: cancellation) { return }
            }
        }
        return result.get(cancellation: cancellation)
    }
}

/// Python requests cancellation through a signed entry point, never a callback.
final class StampCancellationState: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

private final class StampResultBox: @unchecked Sendable {
    private struct SearchState {
        var stamp: Data?
        var rounds: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: SearchState())

    func finishWorker(stamp: [UInt8]?, rounds: UInt64, cancellation: StampCancellationState) {
        state.withLock {
            $0.rounds &+= rounds
            if $0.stamp == nil, let stamp, !cancellation.isCancelled {
                $0.stamp = Data(stamp)
            }
        }
    }

    func shouldStop(cancellation: StampCancellationState) -> Bool {
        cancellation.isCancelled || state.withLock { $0.stamp != nil }
    }

    func get(cancellation: StampCancellationState) -> StampSearchResult {
        state.withLock {
            StampSearchResult(stamp: cancellation.isCancelled ? nil : $0.stamp, rounds: $0.rounds)
        }
    }
}

enum NativeStampJobStatus: Equatable {
    case running
    case succeeded(Data)
    case cancelled
    case failed
}

/// The registry and worker closure retain a job until its native search stops.
final class NativeStampJob: @unchecked Sendable {
    private struct JobState {
        var status: NativeStampJobStatus = .running
        var rounds: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: JobState())
    private let cancellation = StampCancellationState()
    private let workblock: Data
    private let target: StampTarget
    private let size: Int

    init(workblock: Data, target: StampTarget, size: Int) {
        self.workblock = workblock
        self.target = target
        self.size = size
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = StampGenerator.search(
                workblock: workblock, target: target, size: size, cancellation: cancellation
            )
            state.withLock {
                $0.rounds = result.rounds
                if cancellation.isCancelled {
                    $0.status = .cancelled
                } else if let stamp = result.stamp {
                    $0.status = .succeeded(stamp)
                } else {
                    $0.status = .failed
                }
            }
        }
    }

    func cancel() {
        state.withLock {
            cancellation.cancel()
            // Running jobs publish cancellation only once all workers have
            // contributed their rounds. A late cancel still withdraws a proof.
            if $0.status != .running { $0.status = .cancelled }
        }
    }

    /// Proof copying and cancellation share one publication lock.
    func poll(into outStamp: UnsafeMutablePointer<CChar>, capacity: Int, rounds: inout UInt64) -> Int32 {
        let address = UInt(bitPattern: outStamp)
        let snapshot = state.withLock { job -> (Int32, UInt64) in
            switch job.status {
            case .running:
                return (0, 0)
            case .cancelled:
                return (-2, job.rounds)
            case .failed:
                return (-3, job.rounds)
            case .succeeded(let stamp):
                guard capacity >= stamp.count,
                      let destination = UnsafeMutablePointer<CChar>(bitPattern: address) else {
                    return (-1, job.rounds)
                }
                stamp.withUnsafeBytes { raw in
                    _ = memcpy(destination, raw.baseAddress!, stamp.count)
                }
                return (Int32(stamp.count), job.rounds)
            }
        }
        rounds = snapshot.1
        return snapshot.0
    }
}

/// Process-local handles keep asynchronous search cancellable through the C ABI.
enum NativeStampJobRegistry {
    private struct RegistryState {
        var nextID: UInt64 = 1
        var jobs: [UInt64: NativeStampJob] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: RegistryState())

    static func start(workblock: Data, target: StampTarget, size: Int) -> UInt64 {
        guard size > 0, size <= Int32.max else { return 0 }
        let job = NativeStampJob(workblock: workblock, target: target, size: size)
        let jobID = state.withLock { registry -> UInt64 in
            var candidate = registry.nextID
            repeat {
                if candidate == 0 { candidate = 1 }
                if registry.jobs[candidate] == nil { break }
                candidate &+= 1
            } while true
            registry.jobs[candidate] = job
            registry.nextID = candidate &+ 1
            if registry.nextID == 0 { registry.nextID = 1 }
            return candidate
        }
        job.start()
        return jobID
    }

    static func poll(
        _ jobID: UInt64,
        into outStamp: UnsafeMutablePointer<CChar>,
        capacity: Int,
        rounds: inout UInt64
    ) -> Int32? {
        let job = state.withLock { $0.jobs[jobID] }
        return job?.poll(into: outStamp, capacity: capacity, rounds: &rounds)
    }

    @discardableResult
    static func cancel(_ jobID: UInt64) -> Bool {
        let job = state.withLock { $0.jobs[jobID] }
        guard let job else { return false }
        job.cancel()
        return true
    }

    @discardableResult
    static func release(_ jobID: UInt64) -> Bool {
        let job = state.withLock { $0.jobs.removeValue(forKey: jobID) }
        guard let job else { return false }
        job.cancel()
        return true
    }

    static func cancelAll() -> Int {
        let jobs = state.withLock { registry -> [NativeStampJob] in
            let jobs = Array(registry.jobs.values)
            registry.jobs.removeAll(keepingCapacity: true)
            return jobs
        }
        for job in jobs { job.cancel() }
        return jobs.count
    }
}

/// Start a search with an inclusive 32-byte target and positive candidate size.
/// Zero means invalid arguments.
@_cdecl("columba_stamp_job_start")
public func columba_stamp_job_start(
    _ workblock: UnsafePointer<CChar>?,
    _ workblockLen: Int32,
    _ target: UnsafePointer<CChar>?,
    _ targetLen: Int32,
    _ size: Int32
) -> UInt64 {
    guard let workblock, workblockLen >= 0, let target, targetLen == 32, size > 0 else { return 0 }
    let bytes = UnsafeRawBufferPointer(start: target, count: 32)
    guard let threshold = StampTarget(bytes: bytes) else { return 0 }
    let data = Data(bytes: workblock, count: Int(workblockLen))
    return NativeStampJobRegistry.start(workblock: data, target: threshold, size: Int(size))
}

/// Returns 0 while running, the copied proof length on success, -2 cancelled,
/// -3 failed, or -1 for bad arguments/unknown handle. Terminal rounds count
/// failed attempts from every worker, including when cancelled.
@_cdecl("columba_stamp_job_poll")
public func columba_stamp_job_poll(
    _ jobID: UInt64,
    _ outStamp: UnsafeMutablePointer<CChar>?,
    _ outCapacity: Int32,
    _ outRounds: UnsafeMutablePointer<UInt64>?
) -> Int32 {
    guard jobID != 0, let outStamp, outCapacity >= 0, let outRounds else { return -1 }
    var rounds: UInt64 = 0
    guard let status = NativeStampJobRegistry.poll(
        jobID, into: outStamp, capacity: Int(outCapacity), rounds: &rounds
    ) else { return -1 }
    outRounds.pointee = rounds
    return status
}

@_cdecl("columba_stamp_job_cancel")
public func columba_stamp_job_cancel(_ jobID: UInt64) -> Int32 {
    NativeStampJobRegistry.cancel(jobID) ? 0 : -1
}

/// Releasing an active job also cancels its native work.
@_cdecl("columba_stamp_job_release")
public func columba_stamp_job_release(_ jobID: UInt64) -> Int32 {
    NativeStampJobRegistry.release(jobID) ? 0 : -1
}

/// Cancel and detach all jobs during embedded-runtime teardown.
@_cdecl("columba_stamp_jobs_cancel_all")
public func columba_stamp_jobs_cancel_all() -> Int32 {
    Int32(NativeStampJobRegistry.cancelAll())
}
