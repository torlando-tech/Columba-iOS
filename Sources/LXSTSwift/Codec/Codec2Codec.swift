// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  Codec2Codec.swift
//  LXSTSwift
//
//  Swift wrapper for libcodec2 matching Python LXST Codecs/Codec2.py.
//  Provides encode/decode for int16 PCM samples at 8kHz.
//

import Foundation

#if canImport(CCodec2)
import CCodec2

/// Codec2 codec wrapper matching Python LXST Codec2 class.
///
/// Wraps libcodec2 for a given mode. All Codec2 modes operate at 8kHz mono.
/// Encodes/decodes in chunks of `samples_per_frame`.
///
/// Wire format (Python Codec2.py:85): `[mode_header_byte] + [encoded_frames]`
///
/// Python reference: `Codecs/Codec2.py`
public final class Codec2Codec: AudioCodec, @unchecked Sendable {

    public let codecType: LXSTCodecType = .codec2
    public let channels: Int = 1
    public let inputRate: Int = 8000
    public let outputRate: Int = 8000

    private var codec: OpaquePointer?
    private var currentMode: Codec2Mode
    private let samplesPerFrame: Int
    private let bytesPerFrame: Int

    /// Last decoded frame for PLC (frame repetition).
    private var lastDecodedFrame: [Int16]?

    /// Mode header byte for wire format (prepended to encoded data).
    public var modeHeader: UInt8 { currentMode.rawValue }

    /// Create a Codec2 codec instance.
    ///
    /// - Parameter mode: The Codec2 mode (bitrate). Default: codec2_2400
    /// - Throws: `LXSTError.codecError` if codec2 creation fails
    public init(mode: Codec2Mode = .codec2_2400) throws {
        self.currentMode = mode

        let c2Mode = Codec2Codec.c2ModeConstant(mode)
        codec = codec2_create(c2Mode)
        guard codec != nil else {
            throw LXSTError.codecError("Codec2 creation failed for mode \(mode)")
        }

        samplesPerFrame = Int(codec2_samples_per_frame(codec))
        bytesPerFrame = Int(codec2_bytes_per_frame(codec))
    }

    deinit {
        if let c = codec { codec2_destroy(c) }
    }

    /// Switch to a different Codec2 mode.
    ///
    /// - Parameter mode: The new Codec2 mode
    /// - Throws: `LXSTError.codecError` if mode switch fails
    public func setMode(_ mode: Codec2Mode) throws {
        if mode == currentMode { return }

        if let old = codec { codec2_destroy(old) }

        let c2Mode = Codec2Codec.c2ModeConstant(mode)
        codec = codec2_create(c2Mode)
        guard codec != nil else {
            throw LXSTError.codecError("Codec2 mode switch failed for \(mode)")
        }
        currentMode = mode
    }

    /// Encode PCM samples to Codec2.
    ///
    /// Splits input into SPF-sized chunks and encodes each.
    /// Prepends mode header byte (Python Codec2.py:85).
    ///
    /// - Parameter samples: Mono int16 PCM samples at 8kHz
    /// - Returns: `[mode_header] + [encoded_frames...]`
    /// - Throws: `LXSTError.codecError` on failure
    public func encode(_ samples: [Int16]) throws -> Data {
        guard let c = codec else {
            throw LXSTError.codecError("Codec2 not initialized")
        }

        let nFrames = samples.count / samplesPerFrame
        guard nFrames > 0 else {
            throw LXSTError.codecError("Not enough samples for one frame (need \(samplesPerFrame))")
        }

        var encoded = Data(capacity: 1 + nFrames * bytesPerFrame)
        encoded.append(modeHeader)

        var outputBuffer = [UInt8](repeating: 0, count: bytesPerFrame)
        var inputSamples = samples

        for i in 0..<nFrames {
            let start = i * samplesPerFrame
            let end = start + samplesPerFrame
            var frameInput = Array(inputSamples[start..<end])

            frameInput.withUnsafeMutableBufferPointer { pcmPtr in
                outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    codec2_encode(c, outPtr.baseAddress, pcmPtr.baseAddress)
                }
            }
            encoded.append(contentsOf: outputBuffer)
        }

        return encoded
    }

    /// Decode Codec2 data to PCM samples.
    ///
    /// First byte is mode header; remaining bytes are encoded frames.
    /// Python Codec2.py:87-121
    ///
    /// - Parameter data: `[mode_header] + [encoded_frames...]`
    /// - Returns: Decoded mono int16 PCM samples at 8kHz
    /// - Throws: `LXSTError.codecError` on failure
    public func decode(_ data: Data) throws -> [Int16] {
        guard data.count > 1 else {
            throw LXSTError.codecError("Codec2 data too short")
        }

        // Check mode header and switch if needed
        let headerByte = data[data.startIndex]
        if let headerMode = Codec2Mode(rawValue: headerByte), headerMode != currentMode {
            try setMode(headerMode)
        }

        guard let c = codec else {
            throw LXSTError.codecError("Codec2 not initialized after mode switch")
        }

        let frameBytes = Data(data.dropFirst())
        let currentBPF = Int(codec2_bytes_per_frame(c))
        let currentSPF = Int(codec2_samples_per_frame(c))
        let nFrames = frameBytes.count / currentBPF

        guard nFrames > 0 else {
            throw LXSTError.codecError("Not enough data for one frame")
        }

        var decoded = [Int16](repeating: 0, count: nFrames * currentSPF)
        var outputBuffer = [Int16](repeating: 0, count: currentSPF)

        for i in 0..<nFrames {
            let start = frameBytes.startIndex + i * currentBPF
            let end = start + currentBPF
            let encodedFrame = Data(frameBytes[start..<end])

            encodedFrame.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                outputBuffer.withUnsafeMutableBufferPointer { pcmPtr in
                    codec2_decode(c, pcmPtr.baseAddress, bytes.baseAddress)
                }
            }

            let destStart = i * currentSPF
            decoded.replaceSubrange(destStart..<(destStart + currentSPF), with: outputBuffer)
        }

        lastDecodedFrame = decoded
        return decoded
    }

    /// Generate PLC samples by repeating the last decoded frame.
    ///
    /// Codec2 has no built-in PLC, so frame repetition is used — a standard
    /// concealment technique for vocoders that sounds much better than silence.
    ///
    /// - Parameter frameSize: Expected samples (ignored; returns last frame size)
    /// - Returns: Last decoded frame, or nil if no frame has been decoded yet
    public func decodePLC(frameSize: Int) -> [Int16]? {
        lastDecodedFrame
    }

    /// Map Codec2Mode enum to libcodec2 C mode constant.
    private static func c2ModeConstant(_ mode: Codec2Mode) -> Int32 {
        switch mode {
        case .codec2_700C: return CODEC2_MODE_700C
        case .codec2_1200: return CODEC2_MODE_1200
        case .codec2_1300: return CODEC2_MODE_1300
        case .codec2_1400: return CODEC2_MODE_1400
        case .codec2_1600: return CODEC2_MODE_1600
        case .codec2_2400: return CODEC2_MODE_2400
        case .codec2_3200: return CODEC2_MODE_3200
        }
    }
}

#else

/// Codec2 codec stub when CCodec2 is not available.
///
/// Throws `.codecError` on all operations.
public final class Codec2Codec: AudioCodec, @unchecked Sendable {
    public let codecType: LXSTCodecType = .codec2
    public let channels: Int = 1
    public let inputRate: Int = 8000
    public let outputRate: Int = 8000

    public init(mode: Codec2Mode = .codec2_2400) throws {
        throw LXSTError.codecError("Codec2 codec not available: CCodec2 library not linked")
    }

    public func encode(_ samples: [Int16]) throws -> Data {
        throw LXSTError.codecError("Codec2 codec not available")
    }

    public func decode(_ data: Data) throws -> [Int16] {
        throw LXSTError.codecError("Codec2 codec not available")
    }

    public func decodePLC(frameSize: Int) -> [Int16]? { nil }
}

#endif
