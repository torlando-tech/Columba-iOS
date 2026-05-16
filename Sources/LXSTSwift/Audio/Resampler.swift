// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  Resampler.swift
//  LXSTSwift
//
//  Linear interpolation resampler for codec rate mismatches.
//  48kHz ↔ 8kHz for Codec2, 48kHz ↔ 24kHz for some Opus profiles.
//

import Foundation

/// Simple linear interpolation resampler.
///
/// Converts audio between sample rates using linear interpolation.
/// Suitable for voice audio; upgrade to higher quality resampling
/// (e.g., libsamplerate) if artifacts are noticeable.
public struct Resampler: Sendable {

    /// Resample mono float samples from one rate to another.
    ///
    /// Uses linear interpolation between adjacent samples.
    ///
    /// - Parameters:
    ///   - samples: Input samples (mono)
    ///   - fromRate: Source sample rate in Hz
    ///   - toRate: Target sample rate in Hz
    /// - Returns: Resampled samples at the target rate
    public static func resample(
        _ samples: [Float],
        fromRate: Int,
        toRate: Int
    ) -> [Float] {
        guard fromRate != toRate, !samples.isEmpty else { return samples }

        let ratio = Double(toRate) / Double(fromRate)
        let outputCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcFloor = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcFloor))

            let s0 = samples[min(srcFloor, samples.count - 1)]
            let s1 = samples[min(srcFloor + 1, samples.count - 1)]
            output[i] = s0 + frac * (s1 - s0)
        }

        return output
    }

    /// Resample interleaved multi-channel float samples.
    ///
    /// - Parameters:
    ///   - samples: Interleaved input samples
    ///   - channels: Number of channels
    ///   - fromRate: Source sample rate in Hz
    ///   - toRate: Target sample rate in Hz
    /// - Returns: Resampled interleaved samples
    public static func resampleInterleaved(
        _ samples: [Float],
        channels: Int,
        fromRate: Int,
        toRate: Int
    ) -> [Float] {
        guard fromRate != toRate, !samples.isEmpty, channels > 0 else { return samples }

        let framesIn = samples.count / channels
        let ratio = Double(toRate) / Double(fromRate)
        let framesOut = Int(Double(framesIn) * ratio)
        var output = [Float](repeating: 0, count: framesOut * channels)

        for ch in 0..<channels {
            for i in 0..<framesOut {
                let srcIndex = Double(i) / ratio
                let srcFloor = Int(srcIndex)
                let frac = Float(srcIndex - Double(srcFloor))

                let idx0 = min(srcFloor, framesIn - 1) * channels + ch
                let idx1 = min(srcFloor + 1, framesIn - 1) * channels + ch
                output[i * channels + ch] = samples[idx0] + frac * (samples[idx1] - samples[idx0])
            }
        }

        return output
    }

    /// Resample Int16 samples (convenience wrapper).
    public static func resampleInt16(
        _ samples: [Int16],
        channels: Int,
        fromRate: Int,
        toRate: Int
    ) -> [Int16] {
        let floats = int16ToFloat(samples)
        let resampled = resampleInterleaved(floats, channels: channels, fromRate: fromRate, toRate: toRate)
        return floatToInt16(resampled)
    }
}
