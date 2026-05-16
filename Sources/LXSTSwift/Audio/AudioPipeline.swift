// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  AudioPipeline.swift
//  LXSTSwift
//
//  Audio pipeline matching Python LXST Pipeline.py.
//  Orchestrates source→codec→sink chain for encoding/decoding audio.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.lxst.swift", category: "AudioPipeline")

// MARK: - Drift Diagnostics

/// Tracks enqueue/dequeue rate divergence to detect clock drift between
/// the remote transmitter and local playback hardware.
struct DriftTracker: Sendable {
    private(set) var windowStart: ContinuousClock.Instant
    private(set) var enqueueCount: Int = 0
    private(set) var dequeueCount: Int = 0
    private(set) var peakDepth: Int = 0
    /// Number of completed measurement windows.
    private(set) var windowCount: Int = 0

    /// How often to log a drift summary (seconds).
    static let windowDuration: Duration = .seconds(5)

    init() {
        self.windowStart = ContinuousClock.now
    }

    mutating func recordEnqueue(currentDepth: Int) {
        enqueueCount += 1
        peakDepth = max(peakDepth, currentDepth)
    }

    mutating func recordDequeue() {
        dequeueCount += 1
    }

    /// Returns a summary string and resets if the window has elapsed; nil otherwise.
    mutating func checkWindow(currentDepth: Int) -> String? {
        let elapsed = ContinuousClock.now - windowStart
        guard elapsed >= Self.windowDuration else { return nil }

        let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let enqRate = Double(enqueueCount) / elapsedSec
        let deqRate = Double(dequeueCount) / elapsedSec
        let delta = enqRate - deqRate
        windowCount += 1

        let summary = String(format: "DRIFT w=%d %.1fs: enq=%d(%.1f/s) deq=%d(%.1f/s) delta=%+.2f/s depth=%d peak=%d",
                             windowCount, elapsedSec,
                             enqueueCount, enqRate,
                             dequeueCount, deqRate,
                             delta, currentDepth, peakDepth)

        // Reset window
        windowStart = ContinuousClock.now
        enqueueCount = 0
        dequeueCount = 0
        peakDepth = currentDepth

        return summary
    }
}

/// Audio pipeline that connects a source, codec, and sink.
///
/// Matches Python `Pipeline` class. Manages the lifecycle of audio processing:
/// source captures audio, codec encodes/decodes, sink delivers to network or speaker.
///
/// Internally uses Float arrays (range -1.0 to 1.0). Int16 conversion happens
/// at codec boundaries.
public actor AudioPipeline {

    /// Pipeline configuration.
    public struct Config: Sendable {
        public let codecType: LXSTCodecType
        public let sampleRate: Int
        public let channels: Int
        public let frameTimeMs: Int

        public init(codecType: LXSTCodecType, sampleRate: Int, channels: Int, frameTimeMs: Int) {
            self.codecType = codecType
            self.sampleRate = sampleRate
            self.channels = channels
            self.frameTimeMs = frameTimeMs
        }

        /// Create config from a TelephonyProfile.
        public init(profile: TelephonyProfile) {
            self.codecType = profile.codecType
            self.frameTimeMs = profile.frameTimeMs

            switch profile.codecType {
            case .opus:
                let opusProfile = profile.opusProfile!
                self.sampleRate = opusProfile.sampleRate
                self.channels = opusProfile.channels
            case .codec2:
                self.sampleRate = 8000
                self.channels = 1
            default:
                self.sampleRate = 48000
                self.channels = 1
            }
        }

        /// Samples per frame (per channel).
        public var samplesPerFrame: Int {
            sampleRate * frameTimeMs / 1000
        }
    }

    /// Static diagnostics for on-screen debug overlay (updated from processReceived).
    public static var lastPipelineInfo: String = ""

    private let config: Config
    private var isRunning = false

    /// Callback that receives encoded audio frames ready for network transmission.
    private var encodedFrameCallback: (@Sendable (LXSTCodecType, Data) async -> Void)?

    /// Callback that receives decoded float samples ready for playback.
    private var decodedSamplesCallback: (@Sendable ([Float], Int, Int) async -> Void)?

    /// Jitter buffer for smoothing receive-side timing jitter.
    private var jitterBuffer: JitterBuffer?

    /// Periodic playout task that dequeues from the jitter buffer.
    private var playoutTask: Task<Void, Never>?

    /// Active codec reference for PLC generation during underruns.
    private var activeCodec: (any AudioCodec)?

    /// Consecutive playout-loop ticks where the jitter buffer was empty after priming.
    /// PLC is only generated after several consecutive empty ticks to avoid injecting
    /// garbage frames at normal inter-batch boundaries (Android TX_BATCH_SIZE=3 sends
    /// every ~60ms, leaving the buffer empty between batches for up to one batch period).
    private var emptyTickCount: Int = 0

    /// Tracks enqueue/dequeue rate divergence for clock drift detection.
    private var driftTracker = DriftTracker()

    public init(config: Config) {
        self.config = config
    }

    /// Set callback for encoded frames (output of encode pipeline).
    public func setEncodedFrameCallback(
        _ callback: @escaping @Sendable (LXSTCodecType, Data) async -> Void
    ) {
        self.encodedFrameCallback = callback
    }

    /// Set callback for decoded samples (output of decode pipeline).
    /// Parameters: (samples: [Float], sampleRate: Int, channels: Int)
    public func setDecodedSamplesCallback(
        _ callback: @escaping @Sendable ([Float], Int, Int) async -> Void
    ) {
        self.decodedSamplesCallback = callback
    }

    /// Start the pipeline with a codec for PLC and jitter buffering.
    ///
    /// - Parameter codec: The active audio codec (used for PLC on underrun)
    public func start(codec: any AudioCodec) {
        isRunning = true
        self.activeCodec = codec
        let target = playoutTargetDepth
        self.jitterBuffer = JitterBuffer(targetDepth: target, maxDepth: target * 3)
        startPlayoutLoop()
        AudioPipeline.lastPipelineInfo = ""
        logger.info("[PIPELINE] Started with codec at \(self.config.sampleRate)Hz, jitter target=\(target)")
    }

    /// Start the pipeline without jitter buffering (legacy path).
    public func start() {
        isRunning = true
        logger.info("[PIPELINE] Started with codec at \(self.config.sampleRate)Hz")
    }

    public func stop() {
        isRunning = false
        playoutTask?.cancel()
        playoutTask = nil
        activeCodec = nil
        jitterBuffer = nil
        emptyTickCount = 0
        logger.info("[PIPELINE] Stopped")
    }

    /// Frames to accumulate before starting playout (priming window).
    ///
    /// With data-driven delivery (processReceived drains immediately), the player
    /// node gets exactly one batch of frames per batch interval. Since Android sends
    /// TX_BATCH_SIZE=3 frames every 60ms and we play 3 frames in 60ms, the
    /// steady-state player queue hits zero exactly when each new batch arrives.
    ///
    /// targetDepth MUST equal TX_BATCH_SIZE (3) so priming occurs at end of the
    /// first batch. Setting targetDepth > TX_BATCH_SIZE delays priming to batch 2+,
    /// which causes ~60ms of initial silence perceived as "no audio."
    ///
    /// Remaining inter-batch clicks (from network jitter) require a ring-buffer
    /// AudioUnit approach to fix properly (replacing AVAudioPlayerNode).
    private var playoutTargetDepth: Int {
        switch config.frameTimeMs {
        case ...10: return 4   // 40ms priming
        case ...20: return 3   // 60ms priming (= TX_BATCH_SIZE; must not exceed 3)
        case ...60: return 3   // 180ms priming
        default:    return 1   // long frames (320ms+): start on first frame, avoid 640ms delay
        }
    }

    /// Process captured float samples through the encode pipeline.
    ///
    /// Float samples → Int16 → codec.encode() → encoded frame callback
    public func processCapture(_ samples: [Float], codec: any AudioCodec) async {
        guard isRunning else { return }

        let int16Samples = floatToInt16(samples)
        do {
            let encoded = try codec.encode(int16Samples)
            await encodedFrameCallback?(config.codecType, encoded)
        } catch {
            logger.error("[PIPELINE] Encode error: \(error)")
        }
    }

    /// Process received encoded data through the decode pipeline.
    ///
    /// Decodes and enqueues to the jitter buffer. Once primed, immediately drains
    /// all available frames to the player node — this is data-driven scheduling,
    /// avoiding the timer-jitter gaps of a periodic playout loop.
    private var receivedCount = 0
    private var primedLogged = false

    public func processReceived(_ data: Data, codec: any AudioCodec) async {
        guard isRunning else {
            logger.error("[PIPELINE] processReceived called but isRunning=false")
            return
        }

        do {
            let int16Samples = try codec.decode(data)
            let floatSamples = int16ToFloat(int16Samples)
            receivedCount += 1
            if receivedCount == 1 || receivedCount % 50 == 0 {
                logger.debug("[PIPELINE] Decoded frame #\(self.receivedCount, privacy: .public): \(int16Samples.count, privacy: .public) int16 → \(floatSamples.count, privacy: .public) floats")
            }

            if let jitterBuffer {
                await jitterBuffer.enqueue(floatSamples)
                let depth = await jitterBuffer.depth
                driftTracker.recordEnqueue(currentDepth: depth)

                if await jitterBuffer.isPrimed {
                    if !primedLogged {
                        primedLogged = true
                        logger.info("[PIPELINE] Jitter buffer PRIMED, starting drain")
                    }
                    var drained = 0
                    while let ready = await jitterBuffer.dequeue() {
                        emptyTickCount = 0
                        drained += 1
                        driftTracker.recordDequeue()
                        await decodedSamplesCallback?(ready, config.sampleRate, config.channels)
                    }
                    if receivedCount <= 6 {
                        logger.debug("[PIPELINE] Drained \(drained, privacy: .public) frames to callback")
                    }
                }

                // Update static diagnostics every 10 frames for debug overlay
                let stats = await jitterBuffer.stats
                if receivedCount <= 10 || receivedCount % 10 == 0 {
                    AudioPipeline.lastPipelineInfo = "JB: d=\(stats.depth) primed=\(stats.isPrimed) enq=\(stats.totalEnqueued) deq=\(stats.totalDequeued) under=\(stats.totalUnderruns) over=\(stats.totalOverflows) ch=\(config.channels)"
                }

                // Periodic drift diagnostics
                if let summary = driftTracker.checkWindow(currentDepth: stats.depth) {
                    logger.debug("[PIPELINE] \(summary, privacy: .public)")
                    // Also update the overlay with drift info
                    AudioPipeline.lastPipelineInfo += " | \(summary)"
                }
            } else {
                await decodedSamplesCallback?(floatSamples, config.sampleRate, config.channels)
            }
        } catch {
            logger.error("[PIPELINE] Decode error: \(error)")
        }
    }

    // MARK: - Playout Loop

    /// PLC fallback loop: fires every frame interval but only generates concealment audio
    /// when no real data has arrived. Normal frame delivery is data-driven in processReceived.
    private func startPlayoutLoop() {
        let intervalNs = UInt64(config.frameTimeMs) * 1_000_000
        playoutTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Only generate PLC after multiple consecutive empty ticks — this
                // avoids injecting PLC at normal inter-batch boundaries (Android sends
                // every ~60ms so the buffer is legitimately empty between batches).
                // Grace period: 4 ticks × frameTimeMs = 80ms for 20ms frames.
                let depth = await self.jitterBuffer?.depth ?? 0
                let primed = await self.jitterBuffer?.isPrimed ?? false
                if primed && depth == 0 {
                    let shouldPLC = await self.incrementEmptyTick()
                    if shouldPLC {
                        let plc = await self.generatePLC()
                        await self.decodedSamplesCallback?(
                            plc, self.config.sampleRate, self.config.channels)
                    }
                } else {
                    await self.resetEmptyTick()
                }
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    /// Increment empty-tick counter; returns true if PLC grace period (4 ticks) has elapsed.
    private func incrementEmptyTick() -> Bool {
        emptyTickCount += 1
        return emptyTickCount >= 4
    }

    /// Reset empty-tick counter (called when real frames arrive).
    private func resetEmptyTick() {
        emptyTickCount = 0
    }

    /// Generate PLC samples from the active codec, or silence as fallback.
    private func generatePLC() -> [Float] {
        let frameSize = config.samplesPerFrame
        if let codec = activeCodec,
           let plc = codec.decodePLC(frameSize: frameSize) {
            return int16ToFloat(plc)
        }
        return [Float](repeating: 0, count: frameSize * config.channels)
    }
}

// MARK: - Sample Conversion

/// Convert Float samples (-1.0...1.0) to Int16.
func floatToInt16(_ samples: [Float]) -> [Int16] {
    samples.map { sample in
        let clamped = max(-1.0, min(1.0, sample))
        return Int16(clamped * Float(Int16.max))
    }
}

/// Convert Int16 samples to Float (-1.0...1.0).
func int16ToFloat(_ samples: [Int16]) -> [Float] {
    samples.map { Float($0) / Float(Int16.max) }
}
