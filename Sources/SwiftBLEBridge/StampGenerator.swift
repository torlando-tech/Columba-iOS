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
    /// `maxCost` is a hard fail-fast bound: this runs synchronously from Python
    /// via ctypes (holding the GIL for the whole call), so an infeasible cost
    /// would freeze all RNS I/O — message delivery, announces, link events —
    /// with no way to cancel. The practical LXMF range is 0–22 bits (Sideband's
    /// default); 32 leaves generous headroom (~10 bits, 1024×) while keeping
    /// the worst case bounded. (Greptile suggested 64, but 2^33–2^64 work is
    /// hours-to-centuries — still an indefinite GIL freeze — so 32 is the
    /// defensible ceiling; a message requesting more is undeliverable anyway.)
    static let maxCost = 32

    static func generate(
        workblock: Data,
        cost: Int,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Data? {
        guard cost >= 0, cost <= maxCost else { return nil }
        guard !isCancelled() else { return nil }
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
                    if isCancelled() {
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
                // Poll foreign cancellation at a bounded interval rather than
                // crossing the Python C callback boundary for every candidate.
                if rounds & 0xFF == 0,  // at most 256 candidates per worker
                   result.shouldStop(isCancelled: isCancelled) {
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

    func shouldStop(isCancelled: () -> Bool) -> Bool {
        if state.withLock({ $0.cancelled || $0.stamp != nil }) { return true }
        if isCancelled() {
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

/// C-compatible cooperative cancellation callback. A non-zero result requests
/// that all native workers stop and that no stamp be returned.
public typealias ColumbaStampCancellationCallback = @convention(c) (
    UnsafeMutableRawPointer?
) -> Int32

/// Token-aware C ABI used by LXMF's three-argument external generator contract.
/// The legacy `columba_stamp_generate` symbol remains available for callers
/// that do not support cancellation.
@_cdecl("columba_stamp_generate_cancellable")
public func columba_stamp_generate_cancellable(
    _ workblock: UnsafePointer<CChar>?,
    _ workblockLen: Int32,
    _ stampCost: Int32,
    _ outStamp: UnsafeMutablePointer<CChar>?,
    _ cancellationCallback: ColumbaStampCancellationCallback?,
    _ cancellationContext: UnsafeMutableRawPointer?
) -> Int32 {
    guard let workblock, let outStamp, let cancellationCallback,
          workblockLen >= 0, stampCost >= 0 else {
        return -1
    }
    let wb = workblock.withMemoryRebound(to: UInt8.self, capacity: Int(workblockLen)) {
        Data(bytes: $0, count: Int(workblockLen))
    }
    guard let stamp = StampGenerator.generate(
        workblock: wb,
        cost: Int(stampCost),
        isCancelled: { cancellationCallback(cancellationContext) != 0 }
    ), stamp.count == StampGenerator.stampSize else {
        return 0
    }
    stamp.withUnsafeBytes { raw in
        outStamp.withMemoryRebound(to: UInt8.self, capacity: StampGenerator.stampSize) { dst in
            _ = memcpy(dst, raw.baseAddress!, StampGenerator.stampSize)
        }
    }
    return Int32(StampGenerator.stampSize)
}
