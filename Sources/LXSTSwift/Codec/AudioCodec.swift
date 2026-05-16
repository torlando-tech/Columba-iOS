// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  AudioCodec.swift
//  LXSTSwift
//
//  Protocol for audio codecs matching Python LXST Codecs/Codec.py.
//

import Foundation

/// Protocol for audio codecs that encode/decode Int16 PCM frames.
public protocol AudioCodec: Sendable {
    /// The codec type identifier for wire format headers.
    var codecType: LXSTCodecType { get }

    /// Number of audio channels.
    var channels: Int { get }

    /// Input sample rate in Hz.
    var inputRate: Int { get }

    /// Output sample rate in Hz.
    var outputRate: Int { get }

    /// Encode PCM Int16 samples to compressed data.
    ///
    /// - Parameter samples: Array of Int16 PCM samples
    /// - Returns: Encoded audio data (without codec header byte)
    func encode(_ samples: [Int16]) throws -> Data

    /// Decode compressed data to PCM Int16 samples.
    ///
    /// - Parameter data: Encoded audio data (without codec header byte)
    /// - Returns: Array of Int16 PCM samples
    func decode(_ data: Data) throws -> [Int16]

    /// Generate packet loss concealment (PLC) samples.
    ///
    /// Synthesizes audio to fill gaps when packets are lost or late.
    /// Codecs with built-in PLC (e.g. Opus) should override this.
    ///
    /// - Parameter frameSize: Number of samples per channel to generate
    /// - Returns: Int16 PCM samples, or nil if PLC is not supported
    func decodePLC(frameSize: Int) -> [Int16]?
}

extension AudioCodec {
    public func decodePLC(frameSize: Int) -> [Int16]? { nil }
}
