//
//  TelemeterCodecTests.swift
//  RNSAPITests
//
//  Pins the Sideband / Android wire-compat of the ported Telemeter codec:
//  round-trip stability plus a golden byte vector that must stay byte-identical
//  to the old LXMFSwift encoder, Android's `TelemeterCodec.kt` and Python
//  Sideband `Telemeter.packed()`. If the golden vector ever changes, the
//  encoder broke wire compat — fix the encoder, not the vector.
//

import XCTest
import RNSAPI

final class TelemeterCodecTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private let sample = TelemeterCodec.Packet(
        timestamp: 1_700_000_000,
        location: TelemeterCodec.Location(
            latitude: 47.0, longitude: -122.0, altitude: 10.25,
            speed: 0, bearing: 0, accuracy: 5, lastUpdate: 1_700_000_000
        )
    )

    // MARK: - Round-trip

    func testRoundTripWithLocation() {
        XCTAssertEqual(TelemeterCodec.unpack(TelemeterCodec.pack(sample)), sample)
    }

    func testRoundTripWithoutLocation() {
        let packet = TelemeterCodec.Packet(timestamp: 1_700_000_000, location: nil)
        XCTAssertEqual(TelemeterCodec.unpack(TelemeterCodec.pack(packet)), packet)
    }

    func testRoundTripFractionalValues() throws {
        let location = TelemeterCodec.Location(
            latitude: 47.6062, longitude: -122.3321, altitude: 48.15,
            speed: 1.23, bearing: 274.5, accuracy: 7.84, lastUpdate: 1_700_000_042
        )
        let packet = TelemeterCodec.Packet(timestamp: 1_700_000_042, location: location)
        let decoded = try XCTUnwrap(TelemeterCodec.unpack(TelemeterCodec.pack(packet)))
        // Quantization: lat/lon microdegrees (1e-6), alt/speed/bearing/accuracy centi-units.
        XCTAssertEqual(decoded.location?.latitude ?? .nan, 47.6062, accuracy: 5e-7)
        XCTAssertEqual(decoded.location?.longitude ?? .nan, -122.3321, accuracy: 5e-7)
        XCTAssertEqual(decoded.location?.altitude ?? .nan, 48.15, accuracy: 5e-3)
        XCTAssertEqual(decoded.location?.speed ?? .nan, 1.23, accuracy: 5e-3)
        XCTAssertEqual(decoded.location?.bearing ?? .nan, 274.5, accuracy: 5e-3)
        XCTAssertEqual(decoded.location?.accuracy ?? .nan, 7.84, accuracy: 5e-3)
        XCTAssertEqual(decoded.location?.lastUpdate, 1_700_000_042)
    }

    // MARK: - Golden vector (Sideband / Android byte-compat)

    /// Deterministic encoder output for a fixed packet. Derived from the
    /// Sideband Telemeter format: fixmap 0x82; keys .uint(1)/.uint(2) →
    /// fixint 01/02; both timestamps encode `ce 6553f100` (positive .int
    /// delegates to the uint family; 1_700_000_000 = 0x6553F100, verified
    /// against Python `msgpack.packb(1700000000)`); fixarray 0x97; blobs
    /// `c4 04` + int32BE (47000000 = 02cd29c0, −122000000 = f8ba6d80,
    func testGoldenTelemetryVector() {
        XCTAssertEqual(
            hex(TelemeterCodec.pack(sample)),
            "8201ce6553f1000297c40402cd29c0c404f8ba6d80c40400000401c40400000000c40400000000c40201f4ce6553f100"
        )
    }

    func testGoldenVectorStructure() throws {
        let packed = TelemeterCodec.pack(sample)
        // Two-entry fixmap, key order 1 then 2.
        XCTAssertEqual(packed.first, 0x82)
        let value = try unpackMsgPack(packed)
        guard case .map(let map) = value else { return XCTFail("packet is not a msgpack map") }
        XCTAssertEqual(map.count, 2)
        XCTAssertNotNil(map[.uint(1)])
        // Location array: blob widths 4/4/4/4/4/2 + trailing int.
        guard case .array(let arr)? = map[.uint(2)], arr.count == 7 else {
            return XCTFail("SID_LOCATION must be a 7-element array")
        }
        let expectedWidths: [Int] = [4, 4, 4, 4, 4, 2]
        for (index, width) in expectedWidths.enumerated() {
            guard case .binary(let blob) = arr[index] else {
                return XCTFail("element \(index) must be a binary blob")
            }
            XCTAssertEqual(blob.count, width, "element \(index) blob width")
        }
        switch arr[6] { case .int, .uint: break; default: XCTFail("element 6 must be a msgpack int") }
    }

    // MARK: - Decoder tolerance

    func testUnpackRejectsNonMap() {
        XCTAssertNil(TelemeterCodec.unpack(packMsgPack(.array([.uint(1)]))))
        XCTAssertNil(TelemeterCodec.unpack(Data([0xC0])))          // msgpack nil
        XCTAssertNil(TelemeterCodec.unpack(Data()))                // empty
        XCTAssertNil(TelemeterCodec.unpack(Data([0x82, 0x01])))    // truncated
    }

    func testMalformedLocationYieldsPacketWithoutLocation() throws {
        // SID_LOCATION present but wrong shape (3 elements) → packet survives,
        // location nil (mirrors LXMFSwift's decoder).
        let bytes = packMsgPack(.map([
            .uint(1): .int(1_700_000_000),
            .uint(2): .array([.binary(Data([1, 2, 3]))]),
        ]))
        let packet = try XCTUnwrap(TelemeterCodec.unpack(bytes))
        XCTAssertEqual(packet.timestamp, 1_700_000_000)
        XCTAssertNil(packet.location)
    }

    func testMissingTimestampDefaultsToNow() throws {
        let bytes = packMsgPack(.map([.uint(2): .array([.binary(Data([0, 0, 0, 1]))])]))
        let packet = try XCTUnwrap(TelemeterCodec.unpack(bytes))
        let now = Date().timeIntervalSince1970
        XCTAssertLessThanOrEqual(abs(Double(packet.timestamp) - now), 5)
        XCTAssertNil(packet.location)
    }
}
