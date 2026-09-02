//
//  OggOpusInboundNormalizer.swift
//  ColumbaApp
//
//  Inbound Ogg/Opus normalization for stored voice messages.
//
//  WHY THIS EXISTS (the physical evidence, 2026-09-01):
//
//  iOS's AVAudioPlayer plays one-packet-per-page Ogg/Opus but REFUSES streams
//  that pack many packets into one page. Verified byte-for-byte on the
//  physical iPhone (and reproduced exactly by a local AVAudioPlayer harness):
//
//    - Android Columba "Medium Quality" (1 packet/page, 20 ms frames,
//      cumulative granules, version=0)            -> PLAYS
//    - iOS Columba's own recording (1 packet/page, version=0)     -> PLAYS
//    - Sideband "High-quality voice" / PyOgg (up to ~103 packets
//      packed per page, version=0)                -> "Voice message
//      unavailable" (AVAudioPlayer.play() never reaches isPlaying)
//
//  The Sideband file is NOT malformed: libopusfile (Sideband's own decoder)
//  and ffmpeg both decode it to the same sample count. It is a layout the
//  iOS playback stack does not accept. The fix is to re-mux the inbound
//  payload into the one-packet-per-page / cumulative-granule / version=0
//  layout that iOS plays (and that Sideband/libopusfile also accept) before
//  handing it to AVAudioPlayer. This is the defensive inbound pass that
//  VoiceMessagePlayer's header comment anticipated.
//
//  The re-mux is a pure re-containerization: Opus packets are copied
//  verbatim (no re-encode), so the decoded audio is bit-identical. Granules
//  are recomputed as cumulative end-of-packet 48 kHz sample counts with the
//  SAME arithmetic the outbound writer uses (OggOpusGranule.packetSamples48k),
//  so the result is also a no-op for Android's normalizer.
//
//  When is a re-mux needed? Only when the stream deviates from the
//  one-packet-per-page / cumulative-granule / version=0 layout: a page
//  carrying more than one packet, a packet that spans a page boundary, or a
//  non-zero page version byte. Streams already in the good layout (our own
//  outbound, Android's, ffmpeg at typical settings) pass through UNCHANGED
//  (returned as the same bytes) - so the common path costs a single page
//  walk, not a full re-mux.
//

import Foundation

/// Inbound Ogg/Opus re-muxer: converts non-canonical-layout streams into the
/// one-packet-per-page / cumulative-granule / version=0 layout that iOS's
/// AVAudioPlayer plays. Pure (no I/O, no AVFoundation) so it is unit-testable
/// on the host. See the file header for the physical evidence.
public enum OggOpusInboundNormalizer {

    /// Size ceiling (matches the writer + metadata reader: 8 MiB).
    public static let maxFileBytes = 8 * 1024 * 1024

    /// Maximum pages we will walk / emit (guards a hostile stream).
    private static let maxPages = 65_536

    public struct NormalizationResult {
        /// The bytes to play. Identical to the input when no re-mux was needed.
        public let bytes: [UInt8]
        /// True when the stream was re-muxed (layout changed), false when the
        /// input already used the one-packet-per-page layout.
        public let remuxed: Bool
    }

    public enum NormalizeError: Error, Equatable {
        case empty
        case notOgg
        case missingOpusHead
        case noAudioPackets
        case malformedPage
        case sizeLimitExceeded
    }

    /// Normalize an inbound Ogg/Opus payload for playback. Returns the input
    /// unchanged when it is already one-packet-per-page / version=0; re-muxes
    /// when any page carries more than one packet, a packet spans a page
    /// boundary, or a page carries a non-zero version byte. Throws when the
    /// bytes are not a decodable Ogg/Opus stream (the caller then surfaces
    /// the existing unplayable error, unchanged).
    public static func normalize(_ input: [UInt8]) throws -> NormalizationResult {
        guard !input.isEmpty else { throw NormalizeError.empty }
        guard input.count <= maxFileBytes else { throw NormalizeError.sizeLimitExceeded }
        let parsed = try parseStream(input)
        guard let head = parsed.head else { throw NormalizeError.missingOpusHead }
        guard !parsed.audioPackets.isEmpty else { throw NormalizeError.noAudioPackets }

        // Fast path: already one-packet-per-page, no spanning, version 0.
        let needsRemux = parsed.anyMultiPacketPage
            || parsed.anyPacketSpansPages
            || parsed.anyNonZeroVersionPage
        guard needsRemux else {
            return NormalizationResult(bytes: input, remuxed: false)
        }

        // Re-mux: reuse the outbound writer's page emission (version=0, CRC,
        // lacing, cumulative granules) so the output is guaranteed to be the
        // exact layout the writer produces - the one AVAudioPlayer plays.
        let remuxed = try remux(head: head, tags: parsed.tags, packets: parsed.audioPackets)
        return NormalizationResult(bytes: remuxed, remuxed: true)
    }

    // MARK: - Parse

    private struct Stream {
        let head: [UInt8]?
        let tags: [UInt8]?
        let audioPackets: [[UInt8]]
        let anyMultiPacketPage: Bool
        let anyPacketSpansPages: Bool
        let anyNonZeroVersionPage: Bool
    }

    /// Walk the page sequence and reassemble Opus packets across page
    /// boundaries. Packet reassembly is the canonical Ogg rule: accumulate
    /// lacing segments into a buffer and flush it as a complete packet the
    /// first time a lacing value is < 255 (a 255 means the packet continues
    /// into the next segment/page). This is layout-independent, so it works
    /// for one-packet-per-page, many-packets-per-page, and spanning streams.
    private static func parseStream(_ data: [UInt8]) throws -> Stream {
        var head: [UInt8]?
        var tags: [UInt8]?
        var audioPackets: [[UInt8]] = []
        var anyMultiPacketPage = false
        var anyPacketSpansPages = false
        var anyNonZeroVersionPage = false
        var off = 0
        var pageCount = 0
        // Bytes of the in-progress packet (empty when no packet is open).
        var carryover = [UInt8]()

        while off < data.count {
            guard off + 27 <= data.count,
                  data[off] == 0x4F, data[off + 1] == 0x67,
                  data[off + 2] == 0x67, data[off + 3] == 0x53
            else { throw NormalizeError.malformedPage }
            pageCount += 1
            guard pageCount <= maxPages else { throw NormalizeError.sizeLimitExceeded }

            if data[off + 4] != 0 { anyNonZeroVersionPage = true }
            let seg = Int(data[off + 26])
            var payloadSize = 0
            for i in 0..<seg { payloadSize += Int(data[off + 27 + i]) }
            let payloadStart = off + 27 + seg
            let end = payloadStart + payloadSize
            guard end <= data.count else { throw NormalizeError.malformedPage }

            // Split this page's payload into complete packets by walking its
            // lacing table. A page that completes >= 2 packets is a
            // multi-packet page (the layout AVAudioPlayer rejects).
            var flushedThisPage = 0
            var pos = payloadStart
            for i in 0..<seg {
                let l = Int(data[off + 27 + i])
                carryover.append(contentsOf: data[pos..<(pos + l)])
                pos += l
                if l < 255 {
                    guard !carryover.isEmpty else { throw NormalizeError.malformedPage }
                    classify(carryover, head: &head, tags: &tags, audio: &audioPackets)
                    carryover.removeAll(keepingCapacity: true)
                    flushedThisPage += 1
                }
            }
            if flushedThisPage > 1 { anyMultiPacketPage = true }
            // A non-empty carryover after this page's last segment means the
            // in-progress packet's final segment was 255 (the packet
            // continues into the next page) - one more layout AVAudioPlayer
            // rejects. (This subsumes the page's continuation flag, which by
            // the Ogg spec is set exactly when a page's last lacing is 255.)
            if !carryover.isEmpty && end < data.count {
                anyPacketSpansPages = true
            }

            off = end
        }

        if !carryover.isEmpty {
            // Stream ended with a packet still open -> truncated.
            throw NormalizeError.malformedPage
        }
        return Stream(head: head, tags: tags, audioPackets: audioPackets,
                      anyMultiPacketPage: anyMultiPacketPage,
                      anyPacketSpansPages: anyPacketSpansPages,
                      anyNonZeroVersionPage: anyNonZeroVersionPage)
    }

    private static func classify(_ packet: [UInt8],
                                 head: inout [UInt8]?,
                                 tags: inout [UInt8]?,
                                 audio: inout [[UInt8]]) {
        let prefix8 = Array(packet.prefix(8))
        if head == nil && prefix8 == Array("OpusHead".utf8) {
            head = packet
        } else if tags == nil && prefix8 == Array("OpusTags".utf8) {
            tags = packet
        } else {
            audio.append(packet)
        }
    }

    // MARK: - Waveform (real amplitude for the bubble)

    /// Pure bucketing + Android's exact display curve, over the per-frame
    /// mono-folded energy of a decoded stream. Ported from Android
    /// `PcmWaveformAccumulator.levels()`: each bar is the bucket RMS, then
    /// `MIN_LEVEL(0.12) + (1 - 0.12) * (rms / peak)^0.7`, clamped to
    /// `[0.12, 1.0]`. `preSkip` (encoder delay, 48 kHz samples) is trimmed so
    /// the bars align with audible content. Pure (no codec / no I/O) so it is
    /// unit-testable with synthetic energy; the AVAudioFile decode that feeds
    /// it lives in `OggOpusWaveform`.
    public static func peaksFromEnergy(
        _ energyPerFrame: [Double], preSkip: Int, bars: Int
    ) -> [Float] {
        let minLevel = 0.12
        let total = energyPerFrame.count
        guard total > 0, bars >= 1 else { return [] }
        // Index the usable (post-delay) portion of the timeline.
        let skip = min(max(0, preSkip), total)
        let usable = total - skip
        guard usable > 0 else { return Array(repeating: Float(minLevel), count: bars) }

        var bucketEnergy = [Double](repeating: 0, count: bars)
        var bucketCount = [Int](repeating: 0, count: bars)
        for i in skip..<total {
            let usableIndex = i - skip
            let bucket = min(bars - 1, (usableIndex * bars) / usable)
            bucketEnergy[bucket] += energyPerFrame[i]
            bucketCount[bucket] += 1
        }
        var rms = [Double](repeating: 0, count: bars)
        for b in 0..<bars where bucketCount[b] > 0 {
            rms[b] = sqrt(bucketEnergy[b] / Double(bucketCount[b]))
        }
        let peak = rms.max() ?? 0
        guard peak > 0 else { return Array(repeating: Float(minLevel), count: bars) }
        return rms.map { value in
            guard value > 0 else { return Float(minLevel) }
            let normalized = pow(value / peak, 0.7)
            return Float(minLevel + (1 - minLevel) * normalized)
        }
    }

    // MARK: - Re-mux

    /// Emit OpusHead + OpusTags (fresh, canonical), then one Opus packet per
    /// page with cumulative end-of-packet granules and version=0, using the
    /// outbound writer so the page layout is identical to what iOS records.
    /// `OggOpusFileWriter.appendPacket` re-validates each packet's TOC and
    /// throws on an invalid one, so a hostile payload cannot produce a
    /// decodable-but-corrupt re-mux.
    private static func remux(head: [UInt8], tags: [UInt8]?, packets: [[UInt8]]) throws -> [UInt8] {
        // Channels (OpusHead byte 9) and pre-skip (bytes 10-11, LE) carried
        // over from the source header so the re-muxed file decodes to the
        // same sample count with the same encoder-delay trim.
        guard head.count >= 19 else { throw NormalizeError.missingOpusHead }
        let channels = max(1, Int(head[9]))
        let preSkip = Int(head[10]) | (Int(head[11]) << 8)

        // Deterministic serial so the output is stable (and test-assertable).
        let writer = OggOpusFileWriter(channels: channels, preSkip: preSkip, serial: 0xC010BA)
        for packet in packets {
            try writer.appendPacket(packet)
        }
        return try writer.finish()
    }
}
