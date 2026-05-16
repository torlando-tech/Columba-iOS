// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  OpusCodec.swift
//  LXSTSwift
//
//  Swift wrapper for libopus matching Python LXST Codecs/Opus.py.
//  Provides encode/decode for int16 PCM samples.
//

import Foundation
import os.log

private let opusLogger = Logger(subsystem: "com.lxst.swift", category: "OpusCodec")

private func opusPeakMagnitude<S: Sequence>(_ samples: S) -> Int where S.Element == Int16 {
    samples.reduce(0) { current, sample in
        max(current, abs(Int(sample)))
    }
}

#if canImport(COpus)
import COpus

/// Opus codec wrapper matching Python LXST Opus class.
///
/// Wraps libopus encoder and decoder for a given OpusProfile.
/// Handles creation, configuration, encode/decode, and cleanup.
///
/// Python reference: `Codecs/Opus.py`
public final class OpusCodec: AudioCodec, @unchecked Sendable {

    /// Last self-test result for UI diagnostic display.
    public static var lastSelfTestResult: String = ""
    /// Last decode diagnostic for UI display.
    public static var lastDecodeInfo: String = ""
    /// First received frame as base64 (for cross-platform decode testing).
    public static var firstFrameBase64: String = ""
    /// Max peak int16 across ALL decoded frames (reset per codec instance).
    public static var maxPeakInt16: Int16 = 0
    /// Total decode count across current codec instance.
    public static var totalDecodes: Int = 0

    public let codecType: LXSTCodecType = .opus
    public let channels: Int
    public let inputRate: Int
    public let outputRate: Int

    private var encoder: OpaquePointer?
    private var decoder: OpaquePointer?
    private let profile: OpusProfile
    private let maxFrameSize: Int

    /// Create an Opus codec for the given profile.
    ///
    /// - Parameter profile: The Opus profile (determines sample rate, channels, application)
    /// - Throws: `LXSTError.codecError` if encoder/decoder creation fails
    public init(profile: OpusProfile) throws {
        self.profile = profile
        self.channels = profile.channels
        self.inputRate = profile.sampleRate
        self.outputRate = profile.sampleRate

        // Max samples per channel for a 60ms frame at 48kHz
        self.maxFrameSize = 48000 * 60 / 1000 // 2880

        let application: Int32 = profile.application == "voip"
            ? OPUS_APPLICATION_VOIP
            : OPUS_APPLICATION_AUDIO

        var error: Int32 = 0
        encoder = opus_encoder_create(Int32(profile.sampleRate), Int32(channels), application, &error)
        guard error == OPUS_OK, encoder != nil else {
            throw LXSTError.codecError("Opus encoder creation failed: \(error)")
        }

        // Set bitrate ceiling
        opus_encoder_set_bitrate(encoder!, Int32(profile.bitrateCeiling))

        // Set complexity (10 = highest quality)
        opus_encoder_set_complexity(encoder!, Int32(10))

        decoder = opus_decoder_create(Int32(profile.sampleRate), Int32(channels), &error)
        guard error == OPUS_OK, decoder != nil else {
            if let enc = encoder { opus_encoder_destroy(enc) }
            throw LXSTError.codecError("Opus decoder creation failed: \(error)")
        }

        // Reset static diagnostics for new call
        OpusCodec.maxPeakInt16 = 0
        OpusCodec.totalDecodes = 0
        OpusCodec.lastDecodeInfo = ""
        OpusCodec.lastSelfTestResult = ""
        OpusCodec.firstFrameBase64 = ""
    }

    deinit {
        if let enc = encoder { opus_encoder_destroy(enc) }
        if let dec = decoder { opus_decoder_destroy(dec) }
    }

    /// Encode PCM samples to Opus.
    ///
    /// - Parameter samples: Interleaved int16 PCM samples (length = frameSize * channels)
    /// - Returns: Encoded Opus data
    /// - Throws: `LXSTError.codecError` on encoding failure
    public func encode(_ samples: [Int16]) throws -> Data {
        guard let enc = encoder else {
            throw LXSTError.codecError("Encoder not initialized")
        }

        let frameSize = samples.count / channels

        // Calculate max output bytes from bitrate ceiling
        let frameDurationMs = Double(frameSize) / Double(inputRate) * 1000.0
        let maxBytes = profile.maxBytesPerFrame(frameDurationMs: frameDurationMs)
        let outputBufferSize = max(maxBytes, 4000)

        var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)
        let encodedLength = samples.withUnsafeBufferPointer { pcmPtr in
            opus_encode(enc, pcmPtr.baseAddress!, Int32(frameSize),
                       &outputBuffer, Int32(outputBufferSize))
        }

        guard encodedLength > 0 else {
            throw LXSTError.codecError("Opus encode failed: \(encodedLength)")
        }

        return Data(outputBuffer.prefix(Int(encodedLength)))
    }

    /// Decode Opus data to PCM samples.
    ///
    /// - Parameter data: Encoded Opus data
    /// - Returns: Decoded interleaved int16 PCM samples
    /// - Throws: `LXSTError.codecError` on decoding failure
    private var decodeCount = 0
    private var selfTestDone = false

    /// Run a self-test on first decode to verify the decoder works on this platform.
    /// Encodes a sine wave, decodes it, and logs the result.
    private func selfTest() {
        guard !selfTestDone else { return }
        selfTestDone = true

        let spf = maxFrameSize // 2880 samples per channel
        let total = spf * channels

        // Generate 60ms stereo 440Hz sine wave
        var pcm = [Int16](repeating: 0, count: total)
        for i in 0..<spf {
            let sample = Int16(clamping: Int(sin(Double(i) * 2.0 * .pi * 440.0 / Double(profile.sampleRate)) * 10000))
            for c in 0..<channels {
                pcm[i * channels + c] = sample
            }
        }
        let inputPeak = opusPeakMagnitude(pcm)

        do {
            let encoded = try encode(pcm)
            // Decode with a FRESH decoder to avoid polluting our active decoder state
            var error: Int32 = 0
            guard let testDec = opus_decoder_create(Int32(profile.sampleRate), Int32(channels), &error),
                  error == OPUS_OK else {
                opusLogger.warning("[OPUS] Self-test: failed to create test decoder, error=\(error, privacy: .public)")
                return
            }
            defer { opus_decoder_destroy(testDec) }

            var testPcm = [Int16](repeating: 0, count: total)
            let result = encoded.withUnsafeBytes { rawPtr -> Int32 in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                return opus_decode(testDec, bytes.baseAddress, Int32(encoded.count),
                                  &testPcm, Int32(maxFrameSize), 0)
            }
            let outputPeak = opusPeakMagnitude(testPcm.prefix(Int(result) * channels))
            let tocByte = encoded.first.map { String(format: "0x%02x", $0) } ?? "nil"
            let msg = "ST: in=\(inputPeak) enc=\(encoded.count)B dec=\(result)samp peak=\(outputPeak) toc=\(tocByte)"
            OpusCodec.lastSelfTestResult = msg
            opusLogger.info("[OPUS] Self-test: encode \(inputPeak, privacy: .public)→\(encoded.count, privacy: .public)B, decode \(result, privacy: .public) samples, peak=\(outputPeak, privacy: .public) TOC=\(tocByte, privacy: .public)")
        } catch {
            let msg = "ST: FAILED \(error)"
            OpusCodec.lastSelfTestResult = msg
            opusLogger.warning("[OPUS] Self-test encode failed: \(error, privacy: .public)")
        }
    }

    public func decode(_ data: Data) throws -> [Int16] {
        guard let dec = decoder else {
            throw LXSTError.codecError("Decoder not initialized")
        }

        decodeCount += 1
        selfTest() // Runs once on first decode

        var pcmBuffer = [Int16](repeating: 0, count: maxFrameSize * channels)
        let decodedSamples = data.withUnsafeBytes { rawPtr -> Int32 in
            let bytes = rawPtr.bindMemory(to: UInt8.self)
            return opus_decode(dec, bytes.baseAddress, Int32(data.count),
                             &pcmBuffer, Int32(maxFrameSize), 0)
        }

        guard decodedSamples > 0 else {
            throw LXSTError.codecError("Opus decode failed: \(decodedSamples)")
        }

        let result = Array(pcmBuffer.prefix(Int(decodedSamples) * channels))

        // Log raw input bytes and decoded int16 peak
        let peakInt16 = opusPeakMagnitude(result)
        OpusCodec.totalDecodes = decodeCount
        if peakInt16 > Int(OpusCodec.maxPeakInt16) {
            OpusCodec.maxPeakInt16 = Int16(clamping: peakInt16)
        }
        if decodeCount <= 20 || decodeCount % 50 == 0 {
            let first8 = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            OpusCodec.lastDecodeInfo = "D#\(decodeCount) in=\(data.count)B pk=\(peakInt16) maxPk=\(OpusCodec.maxPeakInt16) [\(first8)]"
            opusLogger.debug("[OPUS] decode #\(self.decodeCount, privacy: .public): inBytes=\(data.count, privacy: .public) first8=[\(first8, privacy: .public)] decodedSamples=\(decodedSamples, privacy: .public) channels=\(self.channels, privacy: .public) peakInt16=\(peakInt16, privacy: .public) maxPk=\(OpusCodec.maxPeakInt16, privacy: .public)")
        }
        // Log frames as base64 for cross-platform decode testing
        if decodeCount == 1 || decodeCount == 50 || decodeCount == 100 {
            let b64 = data.base64EncodedString()
            if decodeCount == 1 { OpusCodec.firstFrameBase64 = b64 }
            // Split into 76-char lines for syslog readability
            let chunks = stride(from: 0, to: b64.count, by: 76).map {
                let start = b64.index(b64.startIndex, offsetBy: $0)
                let end = b64.index(start, offsetBy: min(76, b64.distance(from: start, to: b64.endIndex)))
                return String(b64[start..<end])
            }
            for (i, chunk) in chunks.enumerated() {
                opusLogger.debug("[OPUS] FRAME\(self.decodeCount, privacy: .public)_B64 \(i, privacy: .public)/\(chunks.count, privacy: .public): \(chunk, privacy: .public)")
            }
        }

        return result
    }

    /// Generate PLC samples using Opus's built-in packet loss concealment.
    ///
    /// Calls `opus_decode(nil)` which synthesizes audio based on the decoder's
    /// internal state from previous frames.
    ///
    /// - Parameter frameSize: Number of samples per channel to generate
    /// - Returns: Synthesized Int16 PCM samples, or nil on failure
    public func decodePLC(frameSize: Int) -> [Int16]? {
        guard let dec = decoder else { return nil }
        var pcmBuffer = [Int16](repeating: 0, count: frameSize * channels)
        let result = opus_decode(dec, nil, 0, &pcmBuffer, Int32(frameSize), 0)
        guard result > 0 else { return nil }
        return Array(pcmBuffer.prefix(Int(result) * channels))
    }
}

#else

/// Opus codec stub when COpus is not available.
///
/// Throws `.codecError` on all operations.
public final class OpusCodec: AudioCodec, @unchecked Sendable {
    public let codecType: LXSTCodecType = .opus
    public let channels: Int
    public let inputRate: Int
    public let outputRate: Int

    public init(profile: OpusProfile) throws {
        self.channels = profile.channels
        self.inputRate = profile.sampleRate
        self.outputRate = profile.sampleRate
        throw LXSTError.codecError("Opus codec not available: COpus library not linked")
    }

    public func encode(_ samples: [Int16]) throws -> Data {
        throw LXSTError.codecError("Opus codec not available")
    }

    public func decode(_ data: Data) throws -> [Int16] {
        throw LXSTError.codecError("Opus codec not available")
    }

    public func decodePLC(frameSize: Int) -> [Int16]? { nil }
}

#endif
