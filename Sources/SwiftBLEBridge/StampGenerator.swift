//
//  StampGenerator.swift
//  SwiftBLEBridge
//
//  Native multi-threaded LXMF stamp proof-of-work for iOS.
//
//  iOS's embedded CPython ships no `_multiprocessing` module, so upstream
//  LXMF's `LXStamper.job_linux` (multiprocessing-based PoW) throws
//  `ModuleNotFoundError: _multiprocessing` and no stamp is ever produced — so
//  messages to peers that require a stamp cost (e.g. Sideband) are never
//  delivered. macOS/Windows fall back to LXMF's single-threaded `job_simple`,
//  which works but is slow for higher costs.
//
//  This mirrors Columba Android's Kotlin `StampGenerator` (offloading the PoW
//  to native code via LXMF's external-generator hook): brute-force a 32-byte
//  stamp across all CPU cores until SHA-256(workblock ‖ stamp) has `cost`
//  leading zero bits — exactly the condition LXMF's `stamp_valid` (and the
//  receiving Sideband) check. Lives in this module next to the other
//  `columba_*` C-ABI shims so `ctypes.CDLL(None)` resolves it the same proven
//  way. `rns_bridge.py` monkeypatches `LXStamper.generate_stamp` to call in
//  here (keeping LXMF's workblock + value math byte-exact).
//
//  Optimisation over the Android version: the (~750 KB) workblock is absorbed
//  into a SHA-256 context ONCE, then each attempt clones that context (a flat
//  CC_SHA256_CTX value) and finalises over just the 32-byte candidate — instead
//  of re-hashing the whole workblock every round.
//

import Foundation
import CommonCrypto
import os

enum StampGenerator {

    static let stampSize = 32  // RNS.Identity.HASHLENGTH // 8

    /// Find a 32-byte stamp such that SHA-256(workblock ‖ stamp) has at least
    /// `cost` leading zero bits. Multi-threaded across (capped) cores; blocks
    /// until found. Returns nil for an out-of-range / infeasible cost.
    ///
    /// `maxCost` is a hard fail-fast bound for both the legacy synchronous ABI
    /// and native asynchronous jobs. The practical LXMF range is 0–22 bits;
    /// 32 leaves generous headroom while preventing nonsensical or malicious
    /// requests from creating effectively unbounded work.
    static let maxCost = 32

    static func generate(
        workblock: Data,
        cost: Int,
        cancellation: StampCancellationState = StampCancellationState()
    ) -> Data? {
        guard cost >= 0, cost <= maxCost else { return nil }
        guard !cancellation.isCancelled else { return nil }
        if cost == 0 { return Data(repeating: 0, count: stampSize) }

        // Absorb the workblock once. CC_SHA256_CTX is a flat value struct with
        // no internal pointers, so `var ctx = base` is a valid clone of the
        // partial hash state — the key per-round speedup.
        var base = CC_SHA256_CTX()
        CC_SHA256_Init(&base)
        workblock.withUnsafeBytes { raw in
            if let p = raw.baseAddress, raw.count > 0 {
                CC_SHA256_Update(&base, p, CC_LONG(raw.count))
            }
        }

        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let result = StampResultBox()

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            // Distinct random 256-bit start per worker (so workers don't overlap),
            // then increment as a big-endian counter each round — cheaper than
            // drawing fresh randomness per attempt.
            var candidate = [UInt8](repeating: 0, count: stampSize)
            var rng = SystemRandomNumberGenerator()
            for i in 0..<stampSize { candidate[i] = UInt8.random(in: 0...255, using: &rng) }

            var digest = [UInt8](repeating: 0, count: stampSize)
            var rounds: UInt = 0

            while true {
                var ctx = base  // clone partial state (workblock already absorbed)
                _ = candidate.withUnsafeBufferPointer { CC_SHA256_Update(&ctx, $0.baseAddress, CC_LONG(stampSize)) }
                CC_SHA256_Final(&digest, &ctx)

                if leadingZeroBits(digest) >= cost {
                    // Cancellation wins if it raced the proof. StampResultBox
                    // also refuses a proof after any sibling observed cancel.
                    if cancellation.isCancelled {
                        result.cancel()
                    } else {
                        result.trySet(Data(candidate))
                    }
                    return
                }

                // Increment candidate as a 256-bit big-endian counter.
                var idx = stampSize - 1
                while idx >= 0 {
                    candidate[idx] = candidate[idx] &+ 1
                    if candidate[idx] != 0 { break }
                    idx -= 1
                }

                rounds &+= 1
                // Poll native cancellation at a bounded interval rather than
                // taking the cancellation lock for every candidate.
                if rounds & 0xFF == 0,  // at most 256 candidates per worker
                   result.shouldStop(cancellation: cancellation) {
                    return
                }
            }
        }

        return result.get()
    }

    /// Leading zero BITS of a 32-byte big-endian digest.
    @inline(__always)
    private static func leadingZeroBits(_ d: [UInt8]) -> Int {
        var count = 0
        for b in d {
            if b == 0 { count += 8 } else { count += b.leadingZeroBitCount; break }
        }
        return count
    }
}

/// Native cancellation state shared by the job registry and every PoW worker.
/// Python changes this state only through a signed C-ABI cancel function. No
/// dynamically generated Python callback or executable heap trampoline crosses
/// into Swift.
final class StampCancellationState: @unchecked Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

/// Thread-safe shared search state. Cancellation and proof publication are
/// linearized by the same lock, so a proof can never overwrite observed cancel.
private final class StampResultBox: @unchecked Sendable {
    private struct SearchState {
        var stamp: Data?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock<SearchState>(
        initialState: SearchState(stamp: nil)
    )

    func trySet(_ stamp: Data) {
        state.withLock {
            if !$0.cancelled && $0.stamp == nil { $0.stamp = stamp }
        }
    }

    func cancel() {
        state.withLock { $0.cancelled = true; $0.stamp = nil }
    }

    func shouldStop(cancellation: StampCancellationState) -> Bool {
        if state.withLock({ $0.cancelled || $0.stamp != nil }) { return true }
        if cancellation.isCancelled {
            cancel()
            return true
        }
        return state.withLock { $0.cancelled || $0.stamp != nil }
    }

    func get() -> Data? {
        state.withLock { $0.cancelled ? nil : $0.stamp }
    }
}

/// C-ABI shim for Python ctypes (`rns_bridge.py` → `columba_stamp_generate`).
/// Writes the 32-byte stamp into `outStamp` and returns its length (32) on
/// success, 0 if no stamp was produced, -1 on bad arguments.
@_cdecl("columba_stamp_generate")
public func columba_stamp_generate(
    _ workblock: UnsafePointer<CChar>?,
    _ workblockLen: Int32,
    _ stampCost: Int32,
    _ outStamp: UnsafeMutablePointer<CChar>?
) -> Int32 {
    guard let workblock, let outStamp, workblockLen >= 0, stampCost >= 0 else { return -1 }
    let wb = workblock.withMemoryRebound(to: UInt8.self, capacity: Int(workblockLen)) {
        Data(bytes: $0, count: Int(workblockLen))
    }
    guard let stamp = StampGenerator.generate(workblock: wb, cost: Int(stampCost)),
          stamp.count == StampGenerator.stampSize else {
        return 0
    }
    stamp.withUnsafeBytes { raw in
        outStamp.withMemoryRebound(to: UInt8.self, capacity: StampGenerator.stampSize) { dst in
            _ = memcpy(dst, raw.baseAddress!, StampGenerator.stampSize)
        }
    }
    return Int32(StampGenerator.stampSize)
}

/// A native asynchronous PoW operation. The registry owns it while Python polls;
/// the worker closure also retains it until every native worker has stopped.
enum NativeStampJobStatus: Equatable {
    case running
    case succeeded(Data)
    case cancelled
    case failed
}

final class NativeStampJob: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<NativeStampJobStatus>(initialState: .running)
    private let cancellation = StampCancellationState()
    private let completion = DispatchSemaphore(value: 0)
    private let workblock: Data
    private let cost: Int

    init(workblock: Data, cost: Int) {
        self.workblock = workblock
        self.cost = cost
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { completion.signal() }
            let stamp = StampGenerator.generate(
                workblock: workblock,
                cost: cost,
                cancellation: cancellation
            )
            state.withLock { status in
                guard status == .running else { return }
                if cancellation.isCancelled {
                    status = .cancelled
                } else if let stamp {
                    status = .succeeded(stamp)
                } else {
                    status = .failed
                }
            }
        }
    }

    func cancel() {
        state.withLock { status in
            cancellation.cancel()
            status = .cancelled
        }
    }

    /// Poll and copy under the same job lock used by cancellation. This is the
    /// linearization point: a completed cancel can never be followed by a poll
    /// that publishes a previously snapshotted proof.
    func poll(into outStamp: UnsafeMutablePointer<CChar>) -> Int32 {
        state.withLock { status in
            switch status {
            case .running:
                return 0
            case .cancelled:
                return -2
            case .failed:
                return -3
            case .succeeded(let stamp):
                guard stamp.count == StampGenerator.stampSize else { return -3 }
                stamp.withUnsafeBytes { raw in
                    outStamp.withMemoryRebound(
                        to: UInt8.self,
                        capacity: StampGenerator.stampSize
                    ) { dst in
                        _ = memcpy(dst, raw.baseAddress!, StampGenerator.stampSize)
                    }
                }
                return Int32(StampGenerator.stampSize)
            }
        }
    }

    func waitForCompletion(timeout: DispatchTime) -> Bool {
        completion.wait(timeout: timeout) == .success
    }
}

/// Process-wide native job ownership for the synchronous Python external-stamper
/// contract. Registry operations never wait for PoW and never hold this lock
/// while cancelling a job.
enum NativeStampJobRegistry {
    private struct RegistryState {
        var nextID: UInt64 = 1
        var jobs: [UInt64: NativeStampJob] = [:]
    }

    private static let state = OSAllocatedUnfairLock<RegistryState>(
        initialState: RegistryState()
    )

    static func start(workblock: Data, cost: Int) -> UInt64 {
        guard cost >= 0, cost <= StampGenerator.maxCost else { return 0 }
        let job = NativeStampJob(workblock: workblock, cost: cost)
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
        into outStamp: UnsafeMutablePointer<CChar>
    ) -> Int32? {
        let job = state.withLock { $0.jobs[jobID] }
        return job?.poll(into: outStamp)
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

/// Start a native asynchronous stamp operation and return its process-local job
/// ID. Zero means invalid arguments or an unsupported cost.
@_cdecl("columba_stamp_job_start")
public func columba_stamp_job_start(
    _ workblock: UnsafePointer<CChar>?,
    _ workblockLen: Int32,
    _ stampCost: Int32
) -> UInt64 {
    guard let workblock, workblockLen >= 0, stampCost >= 0 else { return 0 }
    let data = workblock.withMemoryRebound(to: UInt8.self, capacity: Int(workblockLen)) {
        Data(bytes: $0, count: Int(workblockLen))
    }
    return NativeStampJobRegistry.start(workblock: data, cost: Int(stampCost))
}

/// Poll a native job. Returns 0 while running, 32 after copying a completed
/// stamp, -2 when cancelled, -3 on generation failure, and -1 for bad input or
/// an unknown/released job.
@_cdecl("columba_stamp_job_poll")
public func columba_stamp_job_poll(
    _ jobID: UInt64,
    _ outStamp: UnsafeMutablePointer<CChar>?
) -> Int32 {
    guard jobID != 0, let outStamp,
          let status = NativeStampJobRegistry.poll(jobID, into: outStamp) else {
        return -1
    }
    return status
}

/// Request cooperative cancellation. Repeated cancellation remains successful
/// until Python releases the job.
@_cdecl("columba_stamp_job_cancel")
public func columba_stamp_job_cancel(_ jobID: UInt64) -> Int32 {
    NativeStampJobRegistry.cancel(jobID) ? 0 : -1
}

/// End Python ownership. Releasing an active job also cancels its native work.
@_cdecl("columba_stamp_job_release")
public func columba_stamp_job_release(_ jobID: UInt64) -> Int32 {
    NativeStampJobRegistry.release(jobID) ? 0 : -1
}

/// Cancel and detach every active job during embedded-runtime teardown.
@_cdecl("columba_stamp_jobs_cancel_all")
public func columba_stamp_jobs_cancel_all() -> Int32 {
    Int32(NativeStampJobRegistry.cancelAll())
}
