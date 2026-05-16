// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  Mixer.swift
//  LXSTSwift
//
//  Audio mixer matching Python LXST Mixer.py.
//  Combines multiple audio sources with gain control.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lxst.swift", category: "Mixer")

/// Audio mixer that combines frames from multiple sources.
///
/// Matches Python `Mixer` class. Sources submit float frames, the mixer
/// sums them with gain control and delivers to a sink callback.
///
/// All operations are sample-wise addition with clamping to [-1.0, 1.0].
public actor Mixer {

    /// Maximum queued frames per source before dropping.
    public static let maxFrames = 8

    /// Per-source frame queue.
    private var incoming: [String: [Data]] = [:]

    /// Gain in dB (0 = unity). Python: `10**(gain/10)`.
    public var gainDb: Float = 0.0

    /// Whether the mixer output is muted.
    public var isMuted: Bool = false

    /// Target frame duration in milliseconds.
    public let targetFrameMs: Int

    /// Sample rate.
    public let sampleRate: Int

    /// Number of channels.
    public let channels: Int

    /// Sink callback for mixed frames.
    private var sinkCallback: (@Sendable ([Float]) async -> Void)?

    private var isRunning = false

    public init(targetFrameMs: Int = 40, sampleRate: Int = 48000, channels: Int = 1) {
        self.targetFrameMs = targetFrameMs
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Set the callback for mixed output frames.
    public func setSinkCallback(_ callback: @escaping @Sendable ([Float]) async -> Void) {
        self.sinkCallback = callback
    }

    /// Submit a decoded float frame from a source.
    ///
    /// - Parameters:
    ///   - frame: Float samples in range [-1.0, 1.0]
    ///   - sourceId: Identifier for the source
    public func handleFrame(_ frame: [Float], from sourceId: String) {
        if incoming[sourceId] == nil {
            incoming[sourceId] = []
        }

        // Drop oldest if over limit
        if let count = incoming[sourceId]?.count, count >= Self.maxFrames {
            incoming[sourceId]?.removeFirst()
        }

        // Store as raw bytes for efficiency
        let data = frame.withUnsafeBytes { Data($0) }
        incoming[sourceId]?.append(data)
    }

    /// Mix all pending frames and deliver to sink.
    ///
    /// Called periodically by the pipeline. Sums all source frames
    /// sample-wise with gain, clamps to [-1.0, 1.0].
    public func mixAndDeliver() async {
        let gain = mixingGain

        var mixedFrame: [Float]? = nil
        var sourceCount = 0

        for sourceId in incoming.keys {
            guard let frames = incoming[sourceId], !frames.isEmpty else { continue }

            let frameData = incoming[sourceId]!.removeFirst()
            let frame = frameData.withUnsafeBytes { rawPtr -> [Float] in
                let floatPtr = rawPtr.bindMemory(to: Float.self)
                return Array(floatPtr)
            }

            if sourceCount == 0 {
                mixedFrame = frame.map { $0 * gain }
            } else if var existing = mixedFrame {
                let count = min(existing.count, frame.count)
                for i in 0..<count {
                    existing[i] += frame[i] * gain
                }
                mixedFrame = existing
            }
            sourceCount += 1
        }

        guard sourceCount > 0, var output = mixedFrame else { return }

        // Clamp to [-1.0, 1.0]
        for i in 0..<output.count {
            output[i] = max(-1.0, min(1.0, output[i]))
        }

        await sinkCallback?(output)
    }

    /// Linear gain factor from dB setting.
    private var mixingGain: Float {
        if isMuted { return 0.0 }
        if gainDb == 0.0 { return 1.0 }
        return powf(10.0, gainDb / 10.0)
    }

    /// Set the muted state.
    public func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    /// Set gain in dB.
    public func setGainDb(_ db: Float) {
        gainDb = db
    }

    /// Remove a source from the mixer.
    public func removeSource(_ sourceId: String) {
        incoming.removeValue(forKey: sourceId)
    }

    /// Number of queued frames for a source (for testing).
    public func queueCount(for sourceId: String) -> Int {
        incoming[sourceId]?.count ?? 0
    }
}
