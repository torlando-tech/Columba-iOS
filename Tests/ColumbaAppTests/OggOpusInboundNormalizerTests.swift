//
//  OggOpusInboundNormalizerTests.swift
//  ColumbaAppTests
//
//  The inbound Ogg/Opus re-muxer (OggOpusInboundNormalizer). The load-bearing
//  case is the Sideband "High-quality voice" layout: many Opus packets packed
//  into a single Ogg page, which libopusfile decodes fine but iOS's
//  AVAudioPlayer refuses. These tests prove the normalizer (a) passes
//  one-packet-per-page streams through UNCHANGED (the common path costs a
//  single page walk), and (b) re-muxes multi-packet-per-page streams into the
//  one-packet-per-page / cumulative-granule / version=0 layout that AVAudio
//  Player plays, copying every Opus packet verbatim (no re-encode) and
//  recomputing cumulative end-of-packet granules (no re-encode, so the decoded
//  audio is bit-identical). The page walker + CRC checks are independent of
//  the writer's own bookkeeping.
//

import XCTest
import Foundation
@testable import ColumbaApp

final class OggOpusInboundNormalizerTests: XCTestCase {

    // MARK: - raw page builders (independent of the production writer)

    /// Emit one Ogg page: 27-byte header (OggS, version 0, flags, granule,
    /// serial, sequence) + lacing table + payload, with a valid Ogg CRC.
    private func rawPage(payload: [UInt8], lacing: [UInt8], granule: UInt64,
                         flags: UInt8, serial: UInt32 = 1,
                         seq: Int32 = 0) -> [UInt8] {
        var page = [UInt8](repeating: 0, count: 27)
        page.replaceSubrange(0..<4, with: [0x4F, 0x67, 0x67, 0x53]) // "OggS"
        page[4] = 0 // version (OggS)
        page[5] = flags
        for i in 0..<8 { page[6 + i] = UInt8((granule >> (i * 8)) & 0xFF) }
        for i in 0..<4 { page[14 + i] = UInt8((serial >> (i * 8)) & 0xFF) }
        for i in 0..<4 { page[18 + i] = UInt8((UInt32(seq) >> (i * 8)) & 0xFF) }
        page[26] = UInt8(lacing.count)
        page.append(contentsOf: lacing)
        page.append(contentsOf: payload)
        let crc = OggOpusGranule.oggChecksum(page, 0, page.count, zeroStoredChecksum: true)
        for i in 0..<4 { page[OggOpusGranule.checksumOffset + i] = UInt8((crc >> (i * 8)) & 0xFF) }
        return page
    }

    private func opusHead(channels: Int = 1, preSkip: Int = 240) -> [UInt8] {
        var h = Array("OpusHead".utf8)
        h.append(0x01)
        h.append(UInt8(channels))
        h.append(UInt8(preSkip & 0xFF)); h.append(UInt8((preSkip >> 8) & 0xFF))
        h.append(contentsOf: [UInt8(48_000 & 0xFF), 0x38, 0x00, 0x00]) // 48000 LE
        h.append(contentsOf: [0x00, 0x00]) // gain
        h.append(0x00) // mapping family
        return h
    }

    private func opusTags() -> [UInt8] {
        Array("OpusTags".utf8) + [0, 0, 0, 0, 0, 0, 0, 0]
    }

    /// A valid Opus 20 ms single-frame packet (TOC 0x98) of `size` bytes.
    private func p20(size: Int) -> [UInt8] { VoiceTestSupport.opusPacket(toc: 0x98, size: size) }

    // MARK: - A: pass-through (already one-packet-per-page)

    func testCanonicalWriterOutputPassesThroughUnchanged() throws {
        let w = OggOpusFileWriter(channels: 1, preSkip: 240)
        try w.appendPacket(p20(size: 40))
        try w.appendPacket(p20(size: 33))
        try w.appendPacket(VoiceTestSupport.opusPacket(toc: 0x90, size: 27)) // 480
        let input = try w.finish()

        let out = try OggOpusInboundNormalizer.normalize(input)
        XCTAssertFalse(out.remuxed, "one-packet-per-page must not be re-muxed")
        XCTAssertEqual(out.bytes, input, "pass-through must return the SAME bytes")
    }

    // MARK: - B: multi-packet-per-page re-mux (the Sideband PyOgg layout)

    /// Two 20 ms Opus packets packed into ONE audio page (granule = cumulative
    /// end-of-last-packet = 1920). This is the layout AVAudioPlayer rejects.
    private func sidebandStyleStream() -> [UInt8] {
        let p1 = p20(size: 30)
        let p2 = p20(size: 25)
        var bytes = [UInt8]()
        bytes.append(contentsOf: rawPage(payload: opusHead(channels: 1, preSkip: 240),
                                         lacing: [UInt8(opusHead(channels: 1, preSkip: 240).count)],
                                         granule: UInt64.max, flags: 0x02)) // OpusHead, BOS
        bytes.append(contentsOf: rawPage(payload: opusTags(),
                                         lacing: [UInt8(opusTags().count)],
                                         granule: UInt64.max, flags: 0x00)) // OpusTags
        // ONE audio page holding BOTH packets.
        bytes.append(contentsOf: rawPage(payload: p1 + p2, lacing: [30, 25],
                                         granule: 1920, flags: 0x00))
        return bytes
    }

    func testMultiPacketPerPageIsRemuxedToOnePacketPerPage() throws {
        let input = sidebandStyleStream()
        let out = try OggOpusInboundNormalizer.normalize(input)
        XCTAssertTrue(out.remuxed, "a multi-packet page must trigger a re-mux")

        let pages = walk(out.bytes)
        // 2 header pages + 2 audio pages (one per packet) = 4.
        XCTAssertEqual(pages.count, 4, "re-mux must split the packed page to one packet/page")

        // Every page version 0 + CRC valid (independent walker).
        for (i, p) in pages.enumerated() {
            let end = i + 1 < pages.count ? pages[i + 1].pageStart : out.bytes.count
            XCTAssertEqual(out.bytes[p.pageStart + 4], 0)
            XCTAssertTrue(VoiceTestSupport.oggPageCRCValid(out.bytes, pageStart: p.pageStart, pageEnd: end),
                          "CRC mismatch on re-muxed page \(i)")
        }

        // Header packets preserved verbatim. The payload starts AFTER the
        // 27-byte header and the lacing table (not at a fixed offset).
        let headStart = 27 + Int(out.bytes[26])
        XCTAssertEqual(Array(out.bytes[headStart..<(headStart + 8)]), Array("OpusHead".utf8))
        // preSkip + channels carried over (duration math preserved).
        XCTAssertEqual(out.bytes[headStart + 9], 1) // channels
        let preSkip = Int(out.bytes[headStart + 10]) | (Int(out.bytes[headStart + 11]) << 8)
        XCTAssertEqual(preSkip, 240)

        // The two audio pages carry the ORIGINAL packets verbatim (no
        // re-encode), each on its own page with a cumulative granule.
        let p1 = p20(size: 30)
        let p2 = p20(size: 25)
        let a0 = audioPayload(of: pages, in: out.bytes, audioPageIndex: 0)
        let a1 = audioPayload(of: pages, in: out.bytes, audioPageIndex: 1)
        XCTAssertEqual(a0, p1, "first Opus packet must be copied verbatim")
        XCTAssertEqual(a1, p2, "second Opus packet must be copied verbatim")
        // Granules: cumulative end-of-packet (960, then 1920).
        XCTAssertEqual(pages[2].granule, 960)
        XCTAssertEqual(pages[3].granule, 1920)

        // Duration reads back from the re-muxed granules (independent reader):
        // (1920 - 240) / 48000 * 1000 = 35 ms.
        let meta = OggOpusMetadataReader.read(out.bytes)
        XCTAssertEqual(meta?.finalGranule, 1920)
        XCTAssertEqual(meta?.durationMs, 35)
    }

    // MARK: - C: non-zero page version triggers a re-mux

    func testNonZeroPageVersionTriggersRemux() throws {
        // Build a one-packet-per-page stream, then corrupt every version byte
        // to 2 (the original writer bug). Layout is fine; only version is not.
        let w = OggOpusFileWriter(channels: 1, preSkip: 240)
        try w.appendPacket(p20(size: 40))
        try w.appendPacket(p20(size: 33))
        var corrupted = try w.finish()
        // Flip byte 4 (version) of each page to 2.
        var off = 0
        while off + 27 <= corrupted.count {
            XCTAssertEqual(corrupted[off], 0x4F) // sanity: page boundary
            corrupted[off + 4] = 2
            let seg = Int(corrupted[off + 26])
            var payloadSize = 0
            for i in 0..<seg { payloadSize += Int(corrupted[off + 27 + i]) }
            off += 27 + seg + payloadSize
        }

        let out = try OggOpusInboundNormalizer.normalize(corrupted)
        XCTAssertTrue(out.remuxed, "a non-zero version byte must trigger a re-mux")
        // Output is back to version 0 on every page.
        let pages = walk(out.bytes)
        for p in pages { XCTAssertEqual(out.bytes[p.pageStart + 4], 0) }
        // Audio still present + decodable duration.
        XCTAssertGreaterThan(out.bytes.count, 100)
        XCTAssertNotNil(OggOpusMetadataReader.read(out.bytes))
    }

    // MARK: - D: fail-closed on non-Ogg / truncated / missing-audio

    func testNonOggInputThrows() {
        XCTAssertThrowsError(try OggOpusInboundNormalizer.normalize(Array("definitely not an ogg stream, far too long to be a page".utf8))) { error in
            _ = error
        }
        // The first page's capture pattern is absent -> notOgg/malformedPage.
        XCTAssertThrowsError(try OggOpusInboundNormalizer.normalize([0x00, 0x01, 0x02, 0x03, 0x04]))
    }

    func testEmptyAndOversizedInputThrows() {
        XCTAssertThrowsError(try OggOpusInboundNormalizer.normalize([]))
        let over = [UInt8](repeating: 0x4F, count: OggOpusInboundNormalizer.maxFileBytes + 1)
        XCTAssertThrowsError(try OggOpusInboundNormalizer.normalize(over))
    }

    func testHeadersOnlyNoAudioThrows() {
        // A valid OpusHead + OpusTags stream with zero audio pages.
        var bytes = [UInt8]()
        bytes.append(contentsOf: rawPage(payload: opusHead(), lacing: [19], granule: UInt64.max, flags: 0x02))
        bytes.append(contentsOf: rawPage(payload: opusTags(), lacing: [16], granule: UInt64.max, flags: 0x00))
        XCTAssertThrowsError(try OggOpusInboundNormalizer.normalize(bytes)) { error in
            XCTAssertEqual(error as? OggOpusInboundNormalizer.NormalizeError, .noAudioPackets)
        }
    }

    func testTruncatedStreamThrows() {
        // A complete first page, then a second page whose payload runs past EOF.
        var bytes = [UInt8]()
        bytes.append(contentsOf: rawPage(payload: opusHead(), lacing: [19], granule: UInt64.max, flags: 0x02))
        bytes.append(contentsOf: rawPage(payload: p20(size: 30), lacing: [30], granule: 960, flags: 0x00))
        let truncated = Array(bytes[0..<(bytes.count - 3)])
        XCTAssertThrowsError(try OggOpusInboundNormalizer.normalize(truncated))
    }

    func testLacingTableShorterThanDeclaredSegmentCountThrows() {
        // Hostile page: the header declares 100 lacing segments but only a
        // handful exist before EOF. Without the pre-read bounds guard this
        // indexed `data[off + 27 + i]` past the buffer and trapped (fatal
        // error) instead of throwing - Greptile finding on PR #194.
        var page = [UInt8](repeating: 0, count: 27)
        page.replaceSubrange(0..<4, with: [0x4F, 0x67, 0x67, 0x53])
        page[4] = 0
        for i in 0..<8 { page[6 + i] = UInt8((UInt64.max >> (i * 8)) & 0xFF) }
        for i in 0..<4 { page[14 + i] = UInt8((1 >> (i * 8)) & 0xFF) }
        for i in 0..<4 { page[18 + i] = UInt8((0 >> (i * 8)) & 0xFF) }
        page[26] = 100 // declared segment count
        page.append(contentsOf: [0x13]) // only 1 lacing byte exists
        page.append(contentsOf: opusHead())
        let crc = OggOpusGranule.oggChecksum(page, 0, page.count, zeroStoredChecksum: true)
        for i in 0..<4 { page[OggOpusGranule.checksumOffset + i] = UInt8((crc >> (i * 8)) & 0xFF) }
        XCTAssertThrowsError(try OggOpusInboundNormalizer.normalize(page)) { error in
            XCTAssertEqual(error as? OggOpusInboundNormalizer.NormalizeError, .malformedPage)
        }
    }

    // MARK: - helpers

    private func walk(_ data: [UInt8]) -> [VoiceTestSupport.OggPage] {
        guard let pages = VoiceTestSupport.oggPages(data) else {
            XCTFail("re-muxed bytes are not a well-formed Ogg page sequence")
            return []
        }
        return pages
    }

    /// The payload of the nth audio page (skipping the 2 header pages).
    private func audioPayload(of pages: [VoiceTestSupport.OggPage], in data: [UInt8], audioPageIndex: Int) -> [UInt8] {
        let p = pages[2 + audioPageIndex]
        let seg = Int(data[p.pageStart + 26])
        var payloadSize = 0
        for i in 0..<seg { payloadSize += Int(data[p.pageStart + 27 + i]) }
        let payloadStart = p.pageStart + 27 + seg
        return Array(data[payloadStart..<(payloadStart + payloadSize)])
    }
}
