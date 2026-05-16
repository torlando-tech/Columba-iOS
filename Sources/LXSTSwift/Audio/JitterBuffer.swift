// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  JitterBuffer.swift
//  LXSTSwift
//
//  Adaptive jitter buffer for smoothing network-induced timing variations
//  in the audio receive path. Frames are decoded on arrival and enqueued,
//  then dequeued at a fixed playout rate by the AudioPipeline.
//

import Foundation

/// FIFO jitter buffer that sits between decode and playout.
///
/// Reticulum links guarantee in-order delivery, so no reordering is needed.
/// The buffer uses a priming gate: it accumulates `targetDepth` frames before
/// releasing any output, preventing initial stutter from early sparse arrivals.
public actor JitterBuffer {

    /// Snapshot of buffer statistics for logging/diagnostics.
    public struct Stats: Sendable {
        public let depth: Int
        public let isPrimed: Bool
        public let totalEnqueued: Int
        public let totalDequeued: Int
        public let totalUnderruns: Int
        public let totalOverflows: Int
    }

    private var queue: [[Float]] = []
    private let targetDepth: Int
    private let maxDepth: Int
    private var primed: Bool = false

    private(set) var totalEnqueued: Int = 0
    private(set) var totalDequeued: Int = 0
    private(set) var totalUnderruns: Int = 0
    private(set) var totalOverflows: Int = 0

    /// Create a jitter buffer.
    ///
    /// - Parameters:
    ///   - targetDepth: Number of frames to accumulate before starting playout (default 3)
    ///   - maxDepth: Maximum queue size; oldest frames dropped on overflow (default 8)
    public init(targetDepth: Int = 3, maxDepth: Int = 8) {
        self.targetDepth = targetDepth
        self.maxDepth = maxDepth
    }

    /// Enqueue a decoded audio frame.
    ///
    /// If the queue exceeds `maxDepth`, the oldest frame is dropped.
    /// Sets `primed = true` once the queue reaches `targetDepth`.
    public func enqueue(_ samples: [Float]) {
        queue.append(samples)
        totalEnqueued += 1

        if queue.count > maxDepth {
            queue.removeFirst()
            totalOverflows += 1
        }

        if !primed && queue.count >= targetDepth {
            primed = true
        }
    }

    /// Dequeue the next frame for playout.
    ///
    /// Returns `nil` if the buffer is not yet primed or is empty (underrun).
    /// Underruns are only counted after the buffer has been primed.
    public func dequeue() -> [Float]? {
        guard primed else { return nil }

        if queue.isEmpty {
            totalUnderruns += 1
            return nil
        }

        totalDequeued += 1
        return queue.removeFirst()
    }

    /// Reset the buffer state (e.g. on profile switch or call restart).
    public func reset() {
        queue.removeAll()
        primed = false
        totalEnqueued = 0
        totalDequeued = 0
        totalUnderruns = 0
        totalOverflows = 0
    }

    /// Current number of frames in the queue.
    public var depth: Int { queue.count }

    /// Whether the buffer has accumulated enough frames to begin playout.
    public var isPrimed: Bool { primed }

    /// Snapshot of current statistics.
    public var stats: Stats {
        Stats(
            depth: queue.count,
            isPrimed: primed,
            totalEnqueued: totalEnqueued,
            totalDequeued: totalDequeued,
            totalUnderruns: totalUnderruns,
            totalOverflows: totalOverflows
        )
    }
}
