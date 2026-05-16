// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  ToneSource.swift
//  LXSTSwift
//
//  Tone generator matching Python LXST Generators.py ToneSource.
//  Generates sine waves for dial tone, busy tone, etc.
//

import Foundation

/// Generates sine wave audio frames.
///
/// Matches Python `ToneSource` class. Generates a continuous sine wave
/// at the specified frequency with gain control and optional fade in/out.
///
/// The LXST dial tone frequency is 382 Hz (TelephonyConstants.dialToneFrequency).
public actor ToneSource {

    /// Default sample rate for tone generation.
    public static let defaultSampleRate = 48000

    /// Default gain (0.1 = -20dB, quiet).
    public static let defaultGain: Float = 0.1

    /// Fade time in milliseconds for smooth start/stop.
    public static let defaultEaseTimeMs = 20

    private let frequency: Double
    private let sampleRate: Int
    private let channels: Int
    private var gain: Float
    private var targetGain: Float
    private let ease: Bool
    private let easeTimeMs: Int

    private var theta: Double = 0.0
    private var easeGain: Float = 0.0
    private var easingOut = false
    private var isRunning = false
    private var easeStep: Float = 0.0
    private var gainStep: Float = 0.0

    /// Create a tone source.
    ///
    /// - Parameters:
    ///   - frequency: Tone frequency in Hz (default: 382 for LXST dial tone)
    ///   - gain: Output gain, 0.0-1.0 (default: 0.1)
    ///   - sampleRate: Sample rate in Hz (default: 48000)
    ///   - channels: Number of channels (default: 1)
    ///   - ease: Whether to fade in/out (default: true)
    ///   - easeTimeMs: Fade time in ms (default: 20)
    public init(
        frequency: Double = Double(TelephonyConstants.dialToneFrequency),
        gain: Float = defaultGain,
        sampleRate: Int = defaultSampleRate,
        channels: Int = 1,
        ease: Bool = true,
        easeTimeMs: Int = defaultEaseTimeMs
    ) {
        self.frequency = frequency
        self.gain = gain
        self.targetGain = gain
        self.sampleRate = sampleRate
        self.channels = channels
        self.ease = ease
        self.easeTimeMs = easeTimeMs

        self.easeStep = 1.0 / Float(sampleRate) / (Float(easeTimeMs) / 1000.0)
        self.gainStep = 0.02 / Float(sampleRate) / (Float(easeTimeMs) / 1000.0)
    }

    /// Start generating tone.
    public func start() {
        easeGain = ease ? 0.0 : 1.0
        easingOut = false
        isRunning = true
    }

    /// Stop generating tone (with optional fade out).
    public func stop() {
        if ease {
            easingOut = true
        } else {
            isRunning = false
        }
    }

    /// Whether the tone is currently generating.
    public var running: Bool { isRunning && !easingOut }

    /// Set the output gain.
    public func setGain(_ newGain: Float) {
        targetGain = newGain
    }

    /// Generate one frame of audio samples.
    ///
    /// - Parameter samplesPerFrame: Number of samples per channel to generate
    /// - Returns: Interleaved float samples in range [-1.0, 1.0]
    public func generateFrame(samplesPerFrame: Int) -> [Float] {
        guard isRunning else { return [Float](repeating: 0, count: samplesPerFrame * channels) }

        var frame = [Float](repeating: 0, count: samplesPerFrame * channels)
        let step = frequency * 2.0 * .pi / Double(sampleRate)

        for n in 0..<samplesPerFrame {
            theta += step
            let amplitude = Float(sin(theta)) * gain * easeGain

            for c in 0..<channels {
                frame[n * channels + c] = amplitude
            }

            // Smooth gain transition
            if targetGain > gain {
                gain += gainStep
                if gain > targetGain { gain = targetGain }
            } else if targetGain < gain {
                gain -= gainStep
                if gain < targetGain { gain = targetGain }
            }

            // Ease in/out
            if ease {
                if !easingOut && easeGain < 1.0 {
                    easeGain += easeStep
                    if easeGain > 1.0 { easeGain = 1.0 }
                } else if easingOut && easeGain > 0.0 {
                    easeGain -= easeStep
                    if easeGain <= 0.0 {
                        easeGain = 0.0
                        easingOut = false
                        isRunning = false
                    }
                }
            }
        }

        return frame
    }
}
