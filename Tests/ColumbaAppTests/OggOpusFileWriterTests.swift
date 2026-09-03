//
//  OggOpusFileWriterTests.swift
//  ColumbaAppTests
//
//  Phase B (plan step 8): the Ogg/Opus muxer output. The load-bearing interop
//  assertion is that each audio page carries CUMULATIVE END-OF-PACKET 48 kHz
//  granules (one packet per page), so Android's Ogg normalizer is a NO-OP on
//  our bytes - the exact condition that makes the file playable by Sideband's
//  LXST/libopusfile path. The page walk below is independent of the writer's
//  own bookkeeping.
//

import XCTest
import Foundation
@testable import ColumbaApp

final class OggOpusFileWriterTests: XCTestCase {

    private func makeWriter(channels: Int = 1, preSkip: Int = 240) -> OggOpusFileWriter {
        OggOpusFileWriter(channels: channels, preSkip: preSkip)
    }

    private func walk(_ data: [UInt8]) -> [VoiceTestSupport.OggPage] {
        guard let pages = VoiceTestSupport.oggPages(data) else {
            XCTFail("bytes are not a well-formed Ogg page sequence")
            return []
        }
        return pages
    }

    private func page(_ pages: [VoiceTestSupport.OggPage], _ data: [UInt8], _ i: Int) -> (header: [UInt8], payloadStart: Int, payload: [UInt8], end: Int) {
        let start = pages[i].pageStart
        let segCount = Int(data[start + 26])
        var payloadSize = 0
        for k in 0..<segCount { payloadSize += Int(data[start + 27 + k]) }
        let payloadStart = start + 27 + segCount
        return (Array(data[start..<(start + 27)]), payloadStart,
                Array(data[payloadStart..<(payloadStart + payloadSize)]), payloadStart + payloadSize)
    }

    func testHeaderPagesAndBOSFlags() {
        let writer = makeWriter(channels: 2, preSkip: 480)
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket())
        let data = try! writer.finish()
        let pages = walk(data)
        XCTAssertEqual(pages.count, 3)

        // Page 0: OpusHead, BOS set, granule -1.
        let h0 = page(pages, data, 0)
        XCTAssertEqual(Array(data[h0.payloadStart..<h0.payloadStart + 8]),
                       Array("OpusHead".utf8))
        XCTAssertEqual(data[h0.payloadStart + 8], 1)                 // version
        XCTAssertEqual(data[h0.payloadStart + 9], 2)                 // channels
        let preSkip = Int(data[h0.payloadStart + 10]) | (Int(data[h0.payloadStart + 11]) << 8)
        XCTAssertEqual(preSkip, 480)
        XCTAssertEqual(h0.header[5] & 0x02, 0x02, "page 0 must be begin-of-stream")
        XCTAssertEqual(OggOpusGranule.readUInt64LE(h0.header, 6), UInt64.max, "granule -1")

        // Page 1: OpusTags, no BOS.
        let h1 = page(pages, data, 1)
        XCTAssertEqual(Array(data[h1.payloadStart..<h1.payloadStart + 8]), Array("OpusTags".utf8))
        XCTAssertEqual(h1.header[5] & 0x02, 0x00)

        // Every page's CRC must validate.
        for (i, p) in pages.enumerated() {
            let end = i + 1 < pages.count ? pages[i + 1].pageStart : data.count
            XCTAssertTrue(VoiceTestSupport.oggPageCRCValid(data, pageStart: p.pageStart, pageEnd: end),
                          "CRC mismatch on page \(i)")
        }
    }

    func testCumulativeEndOfPacketGranulesAreANormalizerNoOp() {
        let writer = makeWriter(channels: 1, preSkip: 240)
        let packets: [[UInt8]] = [
            VoiceTestSupport.opusPacket(toc: 0x98, size: 40),  // 960
            VoiceTestSupport.opusPacket(toc: 0x98, size: 33),  // 960
            VoiceTestSupport.opusPacket(toc: 0x90, size: 27),  // 480
            VoiceTestSupport.opusPacket(toc: 0x98, size: 51),  // 960
            VoiceTestSupport.opusPacket(toc: 0x88, size: 19),  // 240
        ]
        let perPacket = packets.map { try! OggOpusGranule.packetSamples48k($0) }
        for (i, p) in packets.enumerated() { try! writer.appendPacket(p) }
        let data = try! writer.finish()
        let pages = walk(data)
        XCTAssertEqual(pages.count, 2 + packets.count)

        var running: UInt64 = 0
        for (i, packet) in packets.enumerated() {
            let pi = i + 2
            let h = page(pages, data, pi)
            // One packet per page, exact size.
            let segCount = Int(data[pages[pi].pageStart + 26])
            XCTAssertEqual(segCount, 1)
            XCTAssertEqual(data[pages[pi].pageStart + 27], UInt8(packet.count))
            XCTAssertEqual(h.payload, packet)
            // Granule = CUMULATIVE END-OF-PACKET 48 kHz samples.
            running += UInt64(perPacket[i])
            let granule = OggOpusGranule.readUInt64LE(h.header, 6)
            XCTAssertEqual(granule, running,
                           "page \(pi) granule must equal cumulative end-of-packet samples; " +
                           "a regression to packet-START granules breaks Sideband interop")
        }
        XCTAssertEqual(writer.finalGranuleValue, running)

        // Duration via the (independent) metadata reader.
        let meta = OggOpusMetadataReader.read(data)
        XCTAssertEqual(meta?.preSkip, 240)
        XCTAssertEqual(meta?.finalGranule, Int(running))
        XCTAssertEqual(meta?.durationMs, ((Int(running) - 240) * 1_000) / 48_000)
    }

    func testWriterRejectsEmptyAndOversizedPackets() {
        let writer = makeWriter()
        XCTAssertThrowsError(try writer.appendPacket([]))
        let huge = [UInt8](repeating: 0x98, count: 65_026)
        XCTAssertThrowsError(try writer.appendPacket(huge))
    }

    func testFinishRequiresAudio() {
        let writer = makeWriter()
        XCTAssertThrowsError(try writer.finish())
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket())
        XCTAssertNoThrow(try writer.finish())
    }

    func testPreSkipForProfileIsFsOver100() {
        XCTAssertEqual(OggOpusFileWriter.preSkipForProfile(sampleRate: 24_000), 240)
        XCTAssertEqual(OggOpusFileWriter.preSkipForProfile(sampleRate: 48_000), 480)
        XCTAssertEqual(OggOpusFileWriter.preSkipForProfile(sampleRate: 8_000), 80)
    }

    func testMaxFileBytesIs8MiB() {
        XCTAssertEqual(OggOpusFileWriter.maxFileBytes, 8 * 1024 * 1024)
    }

    func testEveryPageUsesOggVersionZero() {
        // Regression: the original writer emitted version byte 2 on every page,
        // which strict Ogg parsers (Sideband's libopusfile, ffmpeg) reject
        // ("Invalid Ogg vers!" / "Failed to open"). The OggS spec mandates
        // version 0. iOS's own AVAudioPlayer is lenient about this byte, so the
        // bug was invisible to our own player but broke every OTHER receiver of
        // our outbound voice. Assert version 0 on every emitted page.
        let w = makeWriter(channels: 2, preSkip: 480)
        _ = try? w.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98, size: 40))
        _ = try? w.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98, size: 33))
        _ = try? w.appendPacket(VoiceTestSupport.opusPacket(toc: 0x90, size: 27))
        let data = try! w.finish()
        let pages = walk(data)
        for p in pages {
            XCTAssertEqual(data[p.pageStart + 4], 0,
                "page @\(p.pageStart) Ogg version byte must be 0 (OggS spec); " +
                "a regression to 2 breaks Sideband/ffmpeg playback of our outbound voice")
        }
    }

    func testPublishToDiskIsAtomicAndBounded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-voice-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.ogg")

        let writer = makeWriter()
        _ = try writer.appendPacket(VoiceTestSupport.opusPacket())
        let bytes = try writer.finish()
        try OggOpusFileWriter.publishToDisk(Data(bytes), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data(bytes))
        // No temp litter.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(remaining, ["out.ogg"])

        // Empty and over-limit payloads are rejected.
        XCTAssertThrowsError(try OggOpusFileWriter.publishToDisk(Data(), to: url))
        let over = Data(repeating: 0, count: OggOpusFileWriter.maxFileBytes + 1)
        XCTAssertThrowsError(try OggOpusFileWriter.publishToDisk(over, to: url))
        // Re-publishing over an existing file works.
        let w2 = makeWriter()
        _ = try w2.appendPacket(VoiceTestSupport.opusPacket(size: 11))
        _ = try w2.appendPacket(VoiceTestSupport.opusPacket(size: 12))
        let bytes2 = try w2.finish()
        try OggOpusFileWriter.publishToDisk(Data(bytes2), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data(bytes2))
    }
}

// MARK: - Metadata reader (fail-closed, duration = (finalGranule - preSkip) @48k)

final class OggOpusMetadataReaderTests: XCTestCase {

    func testReadsDurationFromWriterOutput() {
        let writer = OggOpusFileWriter(channels: 1, preSkip: 240)
        // 960 + 960 + 480 = 2400 granules.
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98))
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98))
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket(toc: 0x90))
        let bytes = try! writer.finish()
        let meta = OggOpusMetadataReader.read(bytes)
        XCTAssertEqual(meta?.finalGranule, 2400)
        XCTAssertEqual(meta?.preSkip, 240)
        // (2400 - 240) / 48000 * 1000 = 45 ms.
        XCTAssertEqual(meta?.durationMs, 45)
    }

    func testReadsCustomPreSkipAndChannels() {
        let writer = OggOpusFileWriter(channels: 2, preSkip: 480)
        _ = try? writer.appendPacket(VoiceTestSupport.opusPacket(toc: 0x98))  // 960
        let meta = OggOpusMetadataReader.read(try! writer.finish())
        XCTAssertEqual(meta?.preSkip, 480)
        XCTAssertEqual(meta?.finalGranule, 960)
        // (960 - 480) / 48000 * 1000 = 10 ms.
        XCTAssertEqual(meta?.durationMs, 10)
    }

    func testFailClosedOnInvalidStreams() throws {
        XCTAssertNil(OggOpusMetadataReader.read([]))
        XCTAssertNil(OggOpusMetadataReader.read(Array("not an ogg stream".utf8)))
        // Headers only (no audio page => no final granule).
        XCTAssertNil(OggOpusMetadataReader.read(try headerOnlyStream()))
        // A truncated final audio page (payload extends past EOF).
        let full = try makeOggWithOnePacket()
        XCTAssertNil(OggOpusMetadataReader.read(Array(full[0..<(full.count - 3)])))
    }

    /// A 2-page (OpusHead + OpusTags) stream with no audio page.
    private func headerOnlyStream() throws -> [UInt8] {
        let w = OggOpusFileWriter(channels: 1, preSkip: 240)
        return w.completedBytes
    }

    private func makeOggWithOnePacket() throws -> [UInt8] {
        let w = OggOpusFileWriter(channels: 1, preSkip: 240)
        try w.appendPacket(VoiceTestSupport.opusPacket())
        return try w.finish()
    }
}
