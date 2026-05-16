// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  AudioFilters.swift
//  LXSTSwift
//
//  Pure Swift audio filters matching Python LXST Filters.py.
//  Provides HighPass, LowPass, BandPass, and AGC.
//

import Foundation

/// Protocol for audio frame processors.
public protocol AudioFilter: Sendable {
    /// Process a frame of float samples.
    ///
    /// - Parameters:
    ///   - frame: Float samples in range [-1.0, 1.0]
    ///   - sampleRate: Sample rate in Hz
    /// - Returns: Filtered samples
    mutating func handleFrame(_ frame: [Float], sampleRate: Int) -> [Float]
}

/// First-order IIR high-pass filter.
///
/// Python `HighPass` (Filters.py:50).
/// `alpha = RC / (RC + dt)` where `RC = 1 / (2*pi*cut)`.
public struct HighPassFilter: AudioFilter {
    public let cutoffHz: Float
    private var alpha: Float = 0.0
    private var lastSampleRate: Int = 0
    private var filterState: Float = 0.0
    private var lastInput: Float = 0.0

    public init(cutoffHz: Float) {
        self.cutoffHz = cutoffHz
    }

    public mutating func handleFrame(_ frame: [Float], sampleRate: Int) -> [Float] {
        guard !frame.isEmpty else { return frame }

        if sampleRate != lastSampleRate {
            lastSampleRate = sampleRate
            let dt: Float = 1.0 / Float(sampleRate)
            let rc: Float = 1.0 / (2.0 * .pi * cutoffHz)
            alpha = rc / (rc + dt)
        }

        var output = [Float](repeating: 0, count: frame.count)

        // First sample
        output[0] = alpha * (filterState + frame[0] - lastInput)

        // Remaining samples
        for i in 1..<frame.count {
            output[i] = alpha * (output[i - 1] + frame[i] - frame[i - 1])
        }

        filterState = output[frame.count - 1]
        lastInput = frame[frame.count - 1]

        return output
    }
}

/// First-order IIR low-pass filter.
///
/// Python `LowPass` (Filters.py:110).
/// `alpha = dt / (RC + dt)` where `RC = 1 / (2*pi*cut)`.
public struct LowPassFilter: AudioFilter {
    public let cutoffHz: Float
    private var alpha: Float = 0.0
    private var lastSampleRate: Int = 0
    private var filterState: Float = 0.0

    public init(cutoffHz: Float) {
        self.cutoffHz = cutoffHz
    }

    public mutating func handleFrame(_ frame: [Float], sampleRate: Int) -> [Float] {
        guard !frame.isEmpty else { return frame }

        if sampleRate != lastSampleRate {
            lastSampleRate = sampleRate
            let dt: Float = 1.0 / Float(sampleRate)
            let rc: Float = 1.0 / (2.0 * .pi * cutoffHz)
            alpha = dt / (rc + dt)
        }

        var output = [Float](repeating: 0, count: frame.count)

        // First sample
        output[0] = alpha * frame[0] + (1.0 - alpha) * filterState

        // Remaining samples
        for i in 1..<frame.count {
            output[i] = alpha * frame[i] + (1.0 - alpha) * output[i - 1]
        }

        filterState = output[frame.count - 1]

        return output
    }
}

/// Band-pass filter combining high-pass and low-pass.
///
/// Python `BandPass` (Filters.py:157).
public struct BandPassFilter: AudioFilter {
    private var highPass: HighPassFilter
    private var lowPass: LowPassFilter

    public init(lowCut: Float, highCut: Float) {
        precondition(lowCut < highCut, "Low-cut must be less than high-cut")
        self.highPass = HighPassFilter(cutoffHz: lowCut)
        self.lowPass = LowPassFilter(cutoffHz: highCut)
    }

    public mutating func handleFrame(_ frame: [Float], sampleRate: Int) -> [Float] {
        let highPassed = highPass.handleFrame(frame, sampleRate: sampleRate)
        return lowPass.handleFrame(highPassed, sampleRate: sampleRate)
    }
}

/// Automatic Gain Control.
///
/// Python `AGC` (Filters.py:176).
/// Adjusts gain to maintain a target output level with attack/release dynamics.
public struct AGCFilter: AudioFilter {
    public let targetLevelDb: Float
    public let maxGainDb: Float
    public let attackTime: Float
    public let releaseTime: Float
    public let holdTime: Float
    public let triggerLevel: Float

    private var targetLinear: Float
    private var maxGainLinear: Float
    private var currentGain: Float = 1.0
    private var holdCounter: Int = 0
    private var attackCoeff: Float = 0.1
    private var releaseCoeff: Float = 0.01
    private var holdSamples: Int = 1000
    private var lastSampleRate: Int = 0

    public init(
        targetLevelDb: Float = -12.0,
        maxGainDb: Float = 12.0,
        attackTime: Float = 0.0001,
        releaseTime: Float = 0.002,
        holdTime: Float = 0.001,
        triggerLevel: Float = 0.003
    ) {
        self.targetLevelDb = targetLevelDb
        self.maxGainDb = maxGainDb
        self.attackTime = attackTime
        self.releaseTime = releaseTime
        self.holdTime = holdTime
        self.triggerLevel = triggerLevel
        self.targetLinear = powf(10.0, targetLevelDb / 10.0)
        self.maxGainLinear = powf(10.0, maxGainDb / 10.0)
    }

    public mutating func handleFrame(_ frame: [Float], sampleRate: Int) -> [Float] {
        guard !frame.isEmpty else { return frame }

        if sampleRate != lastSampleRate {
            lastSampleRate = sampleRate
            attackCoeff = 1.0 - expf(-1.0 / (attackTime * Float(sampleRate)))
            releaseCoeff = 1.0 - expf(-1.0 / (releaseTime * Float(sampleRate)))
            holdSamples = Int(holdTime * Float(sampleRate))
        }

        var output = [Float](repeating: 0, count: frame.count)

        // Process in blocks of ~10ms
        let blockSize = max(1, sampleRate / 100)
        var i = 0

        while i < frame.count {
            let blockEnd = min(i + blockSize, frame.count)
            let block = Array(frame[i..<blockEnd])
            let blockSamples = blockEnd - i

            // RMS of block
            var sumSq: Float = 0
            for s in block { sumSq += s * s }
            let rms = sqrtf(sumSq / Float(blockSamples))

            // Target gain for this block
            var targetGain: Float
            if rms > 1e-9 {
                targetGain = min(targetLinear / max(rms, 1e-9), maxGainLinear)
            } else {
                targetGain = maxGainLinear
            }

            // Below trigger level: maintain current gain
            if rms < triggerLevel {
                targetGain = currentGain
            }

            // Smooth gain adjustment
            if targetGain < currentGain {
                currentGain = attackCoeff * targetGain + (1.0 - attackCoeff) * currentGain
                holdCounter = holdSamples
            } else {
                if holdCounter > 0 {
                    holdCounter -= blockSamples
                } else {
                    currentGain = releaseCoeff * targetGain + (1.0 - releaseCoeff) * currentGain
                }
            }

            // Apply gain
            for j in i..<blockEnd {
                output[j] = frame[j] * currentGain
            }

            i = blockEnd
        }

        // Peak limiting at 0.75
        let peakLimit: Float = 0.75
        var peak: Float = 0
        for s in output { peak = max(peak, abs(s)) }
        if peak > peakLimit {
            let limitGain = peakLimit / max(peak, 1e-9)
            for j in 0..<output.count {
                output[j] *= limitGain
            }
        }

        return output
    }
}
