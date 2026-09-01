//
//  OggOpusGranuleTests.swift
//  ColumbaAppTests
//
//  Phase B (plan step 8): the pure granule/TOC/CRC math. `packetSamples48k`
//  is ported bit-for-bit from Android's normalizer, so these assertions pin
//  the exact Sideband-interop contract (48 kHz code 2.5/5/10/20 ms, 60 ms,
//  20 ms fixed, N+1 multi-frame, the 120 ms ceiling, and error cases).
//

import XCTest
@testable import ColumbaApp

final class OggOpusGranuleTests: XCTestCase {

    // MARK: - TOC decode (packetSamples48k)

    func test48khzCodeDurations() {
        // s=1: 48 kHz, 2.5 / 5 / 10 / 20 ms.
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x80, 0x00]), 120)   // 2.5 ms
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x88, 0x00]), 240)   // 5 ms
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x90, 0x00]), 480)   // 10 ms
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x98, 0x00]), 960)   // 20 ms
    }

    func testCode60ms() {
        // s=0 (bit7 clear, bits5,6 not both 1), code=3 (bits3,4 set) -> 60 ms
        // = 48000*60/1000 = 2880. 0x18: bit7=0, bits6,5=0, bits4,3=1, c=0.
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x18, 0x00]), 2880)
        // Sanity: the neighbouring size=2 (bits3,4 = 10) maps to 40 ms = 1920.
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x30, 0x00]), 1920)
    }

    func testCodeFixed() {
        // s=0, code=11 (bits5,6 set, bit7 clear): bit3 selects 20 ms vs 10 ms.
        // 0x60 (bit3=0) -> 48000/100 = 480 (10 ms); 0x68 (bit3=1) -> 48000/50 = 960 (20 ms).
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x60, 0x00]), 480)
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x68, 0x00]), 960)
    }

    func testMultiFrameNPlus1() {
        // c=3: frame count in the next byte (low 6 bits).
        // 2 frames x 2.5 ms = 240.
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x83, 0x02]), 240)
        // 3 frames x 20 ms (48 kHz) = 2880.
        XCTAssertEqual(try OggOpusGranule.packetSamples48k([0x9B, 0x03]), 2880)
    }

    func testInvalidFrameCountThrows() {
        // c=3 with count 0 -> invalid.
        XCTAssertThrowsError(try OggOpusGranule.packetSamples48k([0x83, 0x00])) {
            XCTAssertEqual($0 as? OggOpusWriterError, .invalidFrameCount)
        }
        // c=3 with count 49 (> 48) -> invalid.
        XCTAssertThrowsError(try OggOpusGranule.packetSamples48k([0x83, 0x31])) {
            XCTAssertEqual($0 as? OggOpusWriterError, .invalidFrameCount)
        }
    }

    func testEmptyAndTruncatedPacketsThrow() {
        XCTAssertThrowsError(try OggOpusGranule.packetSamples48k([])) {
            XCTAssertEqual($0 as? OggOpusWriterError, .emptyPacket)
        }
        // c=3 but no second byte -> truncated multi-frame.
        XCTAssertThrowsError(try OggOpusGranule.packetSamples48k([0x83])) {
            XCTAssertEqual($0 as? OggOpusWriterError, .truncatedMultiFrame)
        }
    }

    // MARK: - CRC-32 (libogg table + algorithm)

    func testCRCTableMatchesPolynomial() {
        XCTAssertEqual(OggOpusGranule.crcTable.count, 256)
        XCTAssertEqual(OggOpusGranule.crcTable[0], 0)
        // table[i] = 8-step non-reflected CRC of the single byte i<<24.
        for i in [1, 2, 3, 7, 0x10, 0x7F, 0x80, 0xFF] {
            var v = UInt32(i) << 24
            for _ in 0..<8 {
                v = (v & 0x8000_0000) != 0 ? ((v << 1) ^ 0x04C1_1DB7) : (v << 1)
            }
            XCTAssertEqual(OggOpusGranule.crcTable[i], v, "table[\(i)]")
        }
    }

    func testChecksumZeroEmptyRangeIsZero() {
        XCTAssertEqual(OggOpusGranule.oggChecksum([], 0, 0), 0)
    }

    func testChecksumIsSensitivityToStoredFieldOnlyWhenZeroed() {
        var page = [UInt8](repeating: 0, count: 27)
        for i in 0..<27 { page[i] = UInt8(i & 0xFF) }
        let normal = OggOpusGranule.oggChecksum(page, 0, 27, zeroStoredChecksum: false)
        let zeroed = OggOpusGranule.oggChecksum(page, 0, 27, zeroStoredChecksum: true)
        // The stored-field bytes (22..25) are non-zero, so zeroing changes the CRC.
        XCTAssertNotEqual(normal, zeroed)
    }

    // MARK: - Endianness helpers + constants

    func testLittleEndianRoundTrip() {
        var buf = [UInt8](repeating: 0, count: 8)
        OggOpusGranule.writeIntLE(0x12345678, into: &buf, 0)
        XCTAssertEqual(OggOpusGranule.readIntLE(buf, 0), 0x12345678)
        OggOpusGranule.writeUInt64LE(0x0102030405060708, into: &buf, 0)
        XCTAssertEqual(OggOpusGranule.readUInt64LE(buf, 0), 0x0102030405060708)
        // Negative INT64 granule (-1) round-trips.
        OggOpusGranule.writeUInt64LE(OggOpusGranule.granuleUndefined, into: &buf, 0)
        XCTAssertEqual(OggOpusGranule.readUInt64LE(buf, 0), UInt64.max)
    }

    func testContainerConstants() {
        XCTAssertEqual(OggOpusGranule.sampleRate, 48_000)
        XCTAssertEqual(OggOpusGranule.oggHeaderSize, 27)
        XCTAssertEqual(OggOpusGranule.checksumOffset, 22)
        XCTAssertEqual(OggOpusGranule.capturePattern, [0x4F, 0x67, 0x67, 0x53])
    }
}
