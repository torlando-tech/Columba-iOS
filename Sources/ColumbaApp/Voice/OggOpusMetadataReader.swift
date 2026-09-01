//
//  OggOpusMetadataReader.swift
//  ColumbaApp
//
//  Reads the duration (and, on request, a bounded PCM-decoded waveform) from
//  finalized Ogg/Opus bytes. Ported from Android Columba's
//  `OggOpusMetadata.kt`: duration comes from the final Ogg granule minus the
//  OpusHead pre-skip, in 48 kHz samples. Parsing is fail-closed at every
//  structural boundary, and the file is size-capped (8 MiB) so a small hostile
//  payload cannot expand into unbounded work. No AVFoundation / no I/O here.
//

import Foundation

public struct OggOpusMetadata {
    public let durationMs: Int
    /// Pre-skip (48 kHz samples) read from the OpusHead.
    public let preSkip: Int
    /// The final audio-page granule position (48 kHz samples).
    public let finalGranule: Int
}

public enum OggOpusMetadataReader {

    private static let sampleRate = 48_000
    private static let maxPages = 65_536
    private static let maxFileBytes = 8 * 1024 * 1024
    private static let headerSize = 27

    /// Read duration (and pre-skip) from Ogg/Opus bytes. Returns nil when the
    /// bytes are not a valid Ogg/Opus stream (fail-closed).
    public static func read(_ bytes: [UInt8]) -> OggOpusMetadata? {
        let data = bytes
        guard !data.isEmpty, data.count <= maxFileBytes else { return nil }
        var offset = 0
        var pageCount = 0
        var preSkip: Int? = nil
        var finalGranule: Int64 = -1

        while offset < data.count && pageCount < maxPages {
            guard offset + headerSize <= data.count, matchesAscii(data, offset, "OggS") else { return nil }
            let segmentCount = Int(data[offset + 26])
            let segmentTableStart = offset + headerSize
            let payloadStart = segmentTableStart + segmentCount
            guard payloadStart <= data.count else { return nil }

            var payloadSize = 0
            for index in 0..<segmentCount {
                payloadSize += Int(data[segmentTableStart + index])
            }
            let pageEnd = payloadStart + payloadSize
            guard pageEnd <= data.count else { return nil }

            let granule = Int64(bitPattern: readUInt64LE(data, offset + 6))
            if granule >= 0 { finalGranule = granule }

            // OpusHead lives in the first page's payload (12+ bytes).
            if payloadSize >= 12, matchesAscii(data, payloadStart, "OpusHead") {
                preSkip = Int(data[payloadStart + 10]) | (Int(data[payloadStart + 11]) << 8)
            }

            offset = pageEnd
            pageCount += 1
        }

        guard let parsedPreSkip = preSkip, finalGranule > 0 else { return nil }
        let playableSamples = finalGranule - Int64(parsedPreSkip)
        guard playableSamples > 0 else { return nil }
        let durationMs = ((playableSamples * 1_000) / Int64(sampleRate)).clamped(to: 1...Int.max)
        return OggOpusMetadata(durationMs: Int(durationMs),
                               preSkip: parsedPreSkip,
                               finalGranule: Int(finalGranule))
    }

    // MARK: - helpers

    private static func matchesAscii(_ b: [UInt8], _ offset: Int, _ value: String) -> Bool {
        let chars = Array(value.utf8)
        guard offset >= 0, offset + chars.count <= b.count else { return false }
        for i in 0..<chars.count where b[offset + i] != chars[i] { return false }
        return true
    }

    private static func readUInt64LE(_ b: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[offset + i]) << (i * 8) }
        return v
    }
}

extension Int64 {
    func clamped(to range: ClosedRange<Int64>) -> Int64 {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
