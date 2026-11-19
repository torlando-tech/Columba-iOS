//
//  LxmfWireCodecTests.swift
//  RNSAPITests
//
//  Pins the decode-only LXMF wire field extractor used by MessageRepository to
//  recover attachments from legacy wire rows: valid wire → fields; anything
//  that isn't wire (field maps, short inputs, null fields) → nil. The strict
//  array discriminator is load-bearing for the wire-vs-field-map discrimination
//  in `recoverFields` / `normalizedFieldMap`.
//

import XCTest
import RNSAPI

final class LxmfWireCodecTests: XCTestCase {
    private let dest = Data(repeating: 0xD7, count: 16)
    private let src = Data(repeating: 0xAB, count: 16)
    private let sig = Data(repeating: 0x00, count: 64)   // never verified

    /// Assemble wire: dest16 + source16 + signature64 + msgpack payload.
    private func wire(_ payload: MessagePackValue) -> Data {
        dest + src + sig + packMsgPack(payload)
    }

    private func payload(fields: MessagePackValue, stamp: MessagePackValue? = nil) -> MessagePackValue {
        var elements: [MessagePackValue] = [
            .double(1_650_000_000.25),
            .binary(Data("subj".utf8)),
            .binary(Data("body".utf8)),
            fields,
        ]
        if let stamp { elements.append(stamp) }
        return .array(elements)
    }

    // MARK: - Valid wire

    func testValidWireRecoversFields() throws {
        let fields: MessagePackValue = .map([
            .uint(6): .array([.string("png"), .binary(Data([0x89, 0x50]))]),
            .uint(4): .string("account"),
            .int(5): .int(42),
            .uint(0x30): .binary(Data(repeating: 0xEE, count: 16)),
        ])
        let got = try XCTUnwrap(LxmfWireCodec.fields(fromWire: wire(payload(fields: fields))))
        let image = try XCTUnwrap(got[6] as? [Any])
        XCTAssertEqual(image.count, 2)
        XCTAssertEqual(image[0] as? String, "png")
        XCTAssertEqual(image[1] as? Data, Data([0x89, 0x50]))
        XCTAssertEqual(got[4] as? String, "account")
        XCTAssertEqual(got[5] as? Int64, 42)
        XCTAssertEqual(got[0x30] as? Data, Data(repeating: 0xEE, count: 16))
    }

    func testNestedArrayAndStringKeyedMapSurvive() throws {
        // FIELD_FILE_ATTACHMENTS shape [[name, bytes]] + string-keyed map value.
        // NB: positive ints pack as fixint and decode back as .uint, which the
        // (LXMFSwift-identical) nested-map table skips — a negative int
        // exercises the .int branch.
        let fields: MessagePackValue = .map([
            .uint(5): .array([
                .array([.string("doc.txt"), .binary(Data([1, 2, 3]))]),
                .array([.string("img.png"), .binary(Data([4, 5]))]),
            ]),
            .uint(0xFD): .map([.string("delta"): .int(-99), .string("label"): .string("x")]),
        ])
        let got = try XCTUnwrap(LxmfWireCodec.fields(fromWire: wire(payload(fields: fields))))
        let files = try XCTUnwrap(got[5] as? [Any])
        XCTAssertEqual(files.count, 2)
        let first = try XCTUnwrap(files[0] as? [Any])
        XCTAssertEqual(first[0] as? String, "doc.txt")
        XCTAssertEqual(first[1] as? Data, Data([1, 2, 3]))
        let meta = try XCTUnwrap(got[0xFD] as? [String: Any])
        XCTAssertEqual(meta["delta"] as? Int64, -99)
        XCTAssertEqual(meta["label"] as? String, "x")
    }

    func testStampElementIgnored() throws {
        // 5th element (PoW stamp) must not disturb field recovery.
        let fields: MessagePackValue = .map([.uint(6): .array([.string("png"), .binary(Data([9]))])])
        let got = try XCTUnwrap(LxmfWireCodec.fields(
            fromWire: wire(payload(fields: fields, stamp: .binary(Data(repeating: 0x77, count: 16))))
        ))
        let image = try XCTUnwrap(got[6] as? [Any])
        XCTAssertEqual(image[0] as? String, "png")
    }

    func testOutOfRangeKeysSkipped() throws {
        // uint key > 255 skipped; valid key survives; all-invalid → nil.
        let mixed: MessagePackValue = .map([.uint(300): .string("nope"), .uint(6): .string("ok")])
        let got = try XCTUnwrap(LxmfWireCodec.fields(fromWire: wire(payload(fields: mixed))))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[6] as? String, "ok")

        let onlyBad = MessagePackValue.map([.uint(300): .string("nope")])
        XCTAssertNil(LxmfWireCodec.fields(fromWire: wire(payload(fields: onlyBad))))
    }

    // MARK: - Rejections

    func testTopLevelFieldMapRejected() {
        // A field map is a top-level msgpack MAP — small ones fail the size
        // guard, large ones fail the array discriminator.
        let smallFieldMap = LxmfFieldCodec.pack([4: "account"])
        XCTAssertLessThan(smallFieldMap.count, 96)
        XCTAssertNil(LxmfWireCodec.fields(fromWire: smallFieldMap))

        let bigFieldMap = LxmfFieldCodec.pack([6: ["png", Data(repeating: 0x01, count: 200)] as [Any]])
        XCTAssertGreaterThan(bigFieldMap.count, 96)
        XCTAssertNil(LxmfWireCodec.fields(fromWire: bigFieldMap))
    }

    func testShortInputRejected() {
        XCTAssertNil(LxmfWireCodec.fields(fromWire: Data()))
        XCTAssertNil(LxmfWireCodec.fields(fromWire: Data(repeating: 0x01, count: 96)))
        // 97 bytes but the payload tail isn't msgpack at all.
        XCTAssertNil(LxmfWireCodec.fields(fromWire: Data(repeating: 0xFF, count: 97)))
    }

    func testNullFieldsRejected() {
        XCTAssertNil(LxmfWireCodec.fields(fromWire: wire(payload(fields: .nil))))
    }

    func testEmptyFieldsMapRejected() {
        XCTAssertNil(LxmfWireCodec.fields(fromWire: wire(payload(fields: .map([:])))))
    }

    func testShortPayloadArrayRejected() {
        // Fewer than 4 payload elements → not wire.
        let short = MessagePackValue.array([.double(1), .binary(Data()), .binary(Data())])
        XCTAssertNil(LxmfWireCodec.fields(fromWire: wire(short)))
    }

    func testElementTypeDiscriminatorEnforced() {
        // [0] must be numeric; [1]/[2] binary-or-string. The fields element
        // is NON-EMPTY so nil can only come from the type checks — with an
        // empty map the empty-map rule would reject regardless of them.
        let okFields = MessagePackValue.map([.uint(1): .binary(Data("f".utf8))])

        let badTimestamp = MessagePackValue.array([
            .string("not-a-timestamp"), .binary(Data("t".utf8)), .binary(Data("c".utf8)), okFields,
        ])
        XCTAssertNil(LxmfWireCodec.fields(fromWire: wire(badTimestamp)))

        let badTitle = MessagePackValue.array([
            .double(1), .array([MessagePackValue.uint(1)]), .binary(Data("c".utf8)), okFields,
        ])
        XCTAssertNil(LxmfWireCodec.fields(fromWire: wire(badTitle)))

        // Positive control: identical array with valid element types recovers
        // fields, proving the two rejections above came from the type checks.
        let good = MessagePackValue.array([
            .double(1), .binary(Data("t".utf8)), .binary(Data("c".utf8)), okFields,
        ])
        XCTAssertEqual(LxmfWireCodec.fields(fromWire: wire(good))?[1] as? Data, Data("f".utf8))
    }
}
