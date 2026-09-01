//
//  OggOpusGranule.swift
//  ColumbaApp
//
//  Pure Ogg/Opus page-granule arithmetic. The per-packet 48 kHz sample count
//  (`packetSamples48k`) is ported bit-for-bit from Android Columba's
//  `OggOpusAndroidTimestampNormalizer.opusPacketSamples` — the post-rollout
//  Sideband-interop fix (PR #1098). The iOS Ogg writer (OggOpusFileWriter)
//  emits granule positions computed with THIS exact function, so the writer's
//  output is a no-op for the normalizer — which is precisely the condition
//  that makes the file playable by Sideband's LXST/libopusfile path (the
//  normalizer's output is the Sideband-proven layout). A unit test asserts the
//  no-op property (see OggOpusFileWriterTests) and would catch any regression
//  to packet-start granules before it ships.
//
//  This file is pure (no AVFoundation / no I/O) so the granule math is unit-
//  testable on the host and in CI without an audio device.
//

import Foundation

public enum OggOpusWriterError: Error, Equatable {
    case emptyPacket
    case truncatedMultiFrame
    case invalidFrameCount
    case invalidPacketDuration
    case sizeLimitExceeded
    case malformed
}

/// Pure Ogg/Opus granule + checksum math (shared by the writer and the
/// validator test). No I/O, no AVFoundation.
public enum OggOpusGranule {

    /// Opus internal sample rate. Granule positions are ALWAYS in 48 kHz
    /// samples (Ogg/Opus container invariant), regardless of the profile's
    /// nominal input rate.
    public static let sampleRate = 48_000

    /// Ogg page header size in bytes.
    public static let oggHeaderSize = 27
    /// Offset of the 4-byte CRC within an Ogg page header.
    public static let checksumOffset = 22
    /// "OggS" capture pattern.
    public static let capturePattern: [UInt8] = [0x4F, 0x67, 0x67, 0x53]

    /// Number of 48 kHz samples represented by one Opus packet, decoded from
    /// its TOC byte. Ported verbatim from Android's `opusPacketSamples`.
    public static func packetSamples48k(_ packet: [UInt8]) throws -> Int {
        guard let tocByte = packet.first else { throw OggOpusWriterError.emptyPacket }
        let toc = Int(tocByte)

        let frames: Int
        switch toc & 0x03 {
        case 0:      frames = 1
        case 1, 2:   frames = 2
        default:     // 3 -> N+1 encoded in the next byte
            guard packet.count >= 2 else { throw OggOpusWriterError.truncatedMultiFrame }
            frames = Int(packet[1] & 0x3F)
        }
        guard (1...48).contains(frames) else { throw OggOpusWriterError.invalidFrameCount }

        let samplesPerFrame: Int
        if toc & 0x80 != 0 {
            // 48 kHz code (2.5/5/10/20 ms)
            samplesPerFrame = (sampleRate << ((toc >> 3) & 0x03)) / 400
        } else if toc & 0x60 == 0x60 {
            // 20 ms fixed
            samplesPerFrame = (toc & 0x08 != 0) ? sampleRate / 50 : sampleRate / 100
        } else {
            // code (5/10/20/60 ms)
            let size = (toc >> 3) & 0x03
            samplesPerFrame = (size == 3) ? sampleRate * 60 / 1_000 : (sampleRate << size) / 100
        }

        let total = frames * samplesPerFrame
        // Bound a single packet's duration (120 ms ceiling) so a hostile or
        // corrupt TOC cannot drive an unbounded granule / decode allocation.
        let cap = sampleRate * 120 / 1_000
        guard total >= 1, total <= cap else { throw OggOpusWriterError.invalidPacketDuration }
        return total
    }

    // MARK: - Ogg CRC-32 (libogg-compatible, ported from the normalizer)

    /// Ogg's CRC-32 lookup table (poly 0x04c11db7, init 0, no reflection, no
    /// final XOR) — identical to libogg and to the Android normalizer's
    /// `CRC_LOOKUP`.
    public static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index) << 24
            for _ in 0..<8 {
                value = (value & 0x8000_0000) != 0 ? ((value << 1) ^ 0x04C1_1DB7) : (value << 1)
            }
            return value
        }
    }()

    /// Compute the Ogg page CRC over `bytes[start..<end]`. When
    /// `zeroStoredChecksum` is true the 4-byte stored-checksum field
    /// (`start + checksumOffset ..< start + checksumOffset + 4`) is treated as
    /// zero, as required to verify / (re)compute a page's own CRC.
    public static func oggChecksum(
        _ bytes: [UInt8],
        _ start: Int,
        _ end: Int,
        zeroStoredChecksum: Bool = false
    ) -> UInt32 {
        var checksum: UInt32 = 0
        var index = start
        while index < end {
            let inChecksumField = zeroStoredChecksum
                && index >= start + checksumOffset
                && index < start + checksumOffset + 4
            let value = inChecksumField ? 0 : UInt32(bytes[index])
            checksum = (checksum << 8) ^ crcTable[Int(((checksum >> 24) ^ value) & 0xFF)]
            index += 1
        }
        return checksum
    }

    // MARK: - Little-endian helpers

    public static func readIntLE(_ b: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: UInt32(b[offset])
            | UInt32(b[offset + 1]) << 8
            | UInt32(b[offset + 2]) << 16
            | UInt32(b[offset + 3]) << 24)
    }

    public static func readUInt64LE(_ b: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[offset + i]) << (i * 8) }
        return v
    }

    /// The granule position is an INT64 in the Ogg page; libopusfile reads it
    /// signed. -1 (0xFFFFFFFFFFFFFFFF) marks a header page with no granule.
    public static var granuleUndefined: UInt64 { UInt64.max }

    public static func writeIntLE(_ value: Int32, into b: inout [UInt8], _ offset: Int) {
        b[offset]     = UInt8(value & 0xFF)
        b[offset + 1] = UInt8((value >> 8) & 0xFF)
        b[offset + 2] = UInt8((value >> 16) & 0xFF)
        b[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    public static func writeUInt64LE(_ value: UInt64, into b: inout [UInt8], _ offset: Int) {
        for i in 0..<8 { b[offset + i] = UInt8((value >> (i * 8)) & 0xFF) }
    }
}
