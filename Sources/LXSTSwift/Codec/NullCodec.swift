// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  NullCodec.swift
//  LXSTSwift
//
//  Passthrough codec matching Python LXST Codecs/Codec.py Null class.
//

import Foundation

/// Null/passthrough codec. Passes audio through without encoding/decoding.
public struct NullCodec: AudioCodec, Sendable {
    public let codecType: LXSTCodecType = .null
    public let channels: Int = 1
    public let inputRate: Int = 48000
    public let outputRate: Int = 48000

    public init() {}

    public func encode(_ samples: [Int16]) throws -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var s = sample.littleEndian
            data.append(Data(bytes: &s, count: 2))
        }
        return data
    }

    public func decode(_ data: Data) throws -> [Int16] {
        guard data.count % 2 == 0 else {
            throw LXSTError.codecError("Null codec: data length must be even")
        }
        var samples = [Int16]()
        samples.reserveCapacity(data.count / 2)
        for i in stride(from: data.startIndex, to: data.endIndex, by: 2) {
            let sample = Int16(littleEndian: data[i...].withUnsafeBytes { $0.load(as: Int16.self) })
            samples.append(sample)
        }
        return samples
    }
}
