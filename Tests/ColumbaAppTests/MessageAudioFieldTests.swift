//
//  MessageAudioFieldTests.swift
//  ColumbaAppTests
//
//  Phase D (plan step 16): the wire field-7 contract. Covers the outbound
//  `buildFieldMap` dual-write target (`[FIELD_AUDIO]: [mode, bytes]`), the
//  inbound lenient `[Int, Data]` parse at the Message boundary, unsupported
//  / custom mode handling, and the RnsAudio <-> AudioAttachment value mapping.
//

import XCTest
import RNSAPI
@testable import ColumbaApp

final class MessageAudioFieldTests: XCTestCase {

    // MARK: - Outbound: buildFieldMap writes FIELD_AUDIO = [mode, bytes]

    func testBuildFieldMapWritesAudioField() {
        let audio = RnsAudio(mode: Int(LxmfFields.AM_CODEC2_2400), bytes: Data([1, 2, 3]))
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: nil, imageFormat: nil, fileAttachments: nil,
            audioAttachment: audio, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil, extraFields: nil
        )
        let value = fields[LxmfFields.FIELD_AUDIO] as? [Any]
        XCTAssertNotNil(value, "FIELD_AUDIO must be written when an audio attachment is set")
        XCTAssertEqual(value?.count, 2)
        guard let value, let mode = (value[0] as? Int) ?? (value[0] as? UInt8).map(Int.init) else {
            XCTFail("FIELD_AUDIO must be [Int mode, Data bytes]"); return
        }
        XCTAssertEqual(mode, Int(LxmfFields.AM_CODEC2_2400))
        XCTAssertEqual(value[1] as? Data, Data([1, 2, 3]))
        // Round-trips through the lenient inbound parser.
        let back = AudioAttachment.fromWireValue(value)
        XCTAssertEqual(back?.mode, .codec2_2400)
        XCTAssertEqual(back?.bytes, Data([1, 2, 3]))
    }

    func testBuildFieldMapOmitsAudioWhenNil() {
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: nil, imageFormat: nil, fileAttachments: nil,
            audioAttachment: nil, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil, extraFields: nil
        )
        XCTAssertNil(fields[LxmfFields.FIELD_AUDIO])
    }

    func testBuildFieldMapAudioCoexistsWithImage() {
        let img = Data([0xFF, 0xD8, 0xFF])
        let audio = RnsAudio(mode: Int(LxmfFields.AM_OPUS_OGG), bytes: Data([9]))
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: img, imageFormat: "jpeg", fileAttachments: nil,
            audioAttachment: audio, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil, extraFields: nil
        )
        XCTAssertNotNil(fields[LxmfFields.FIELD_IMAGE])
        guard let v = fields[LxmfFields.FIELD_AUDIO] as? [Any], let m = v[0] as? Int else {
            XCTFail("FIELD_AUDIO must be [Int mode, Data bytes]"); return
        }
        XCTAssertEqual(m, Int(LxmfFields.AM_OPUS_OGG))
    }

    // MARK: - Inbound: Message.audioAttachment(from:) lenient parse

    private func fields(_ value: Any?) -> [UInt8: Any] {
        [LxmfFields.FIELD_AUDIO: value]
    }

    func testInboundParseAcceptsCanonicalShapes() {
        let payload = Data([5, 6, 7])
        // Plain Int mode.
        let m1 = Message.audioAttachment(from: fields([Int(0x08), payload]))
        XCTAssertEqual(m1?.mode, .codec2_2400)
        XCTAssertEqual(m1?.bytes, payload)
        // Unsigned 8-bit mode.
        let m2 = Message.audioAttachment(from: fields([UInt8(0x10), payload]))
        XCTAssertEqual(m2?.mode, .opusOgg)
        // 32-bit mode.
        let m3 = Message.audioAttachment(from: fields([Int32(0x04), payload]))
        XCTAssertEqual(m3?.mode, .codec2_1200)
    }

    func testInboundParseRejectsBadShapes() {
        XCTAssertNil(Message.audioAttachment(from: nil))
        var empty: [UInt8: Any] = [:]
        XCTAssertNil(Message.audioAttachment(from: empty))
        XCTAssertNil(Message.audioAttachment(from: fields(Data([1, 2]))))          // not an array
        XCTAssertNil(Message.audioAttachment(from: fields([Int(0x04)])))            // too short
        XCTAssertNil(Message.audioAttachment(from: fields(["x", Data([1])] as [Any]))) // non-int mode
        XCTAssertNil(Message.audioAttachment(from: fields([Int(0x04), "nope"])))    // non-Data payload
    }

    func testInboundUnsupportedModeRendersAsCustom() {
        // A non-canonical wire mode is accepted as .custom so the message
        // still renders (as a non-playable bubble) instead of being dropped.
        let m = Message.audioAttachment(from: fields([Int(0x42), Data([1, 2])]))
        XCTAssertEqual(m?.mode, .custom)
        XCTAssertFalse(m?.mode.isCodec2 ?? true)
        XCTAssertNil(VoiceMessageFormat.fromWireMode(0x42))
    }

    func testInboundOpusModeHasNoRecoverableProfile() {
        // Opus bitrate is not on the wire: the attachment parses, but there is
        // no canonical VoiceMessageFormat (playback uses the mode only).
        let m = Message.audioAttachment(from: fields([Int(0x10), Data([3])]))
        XCTAssertEqual(m?.mode, .opusOgg)
        XCTAssertNil(VoiceMessageFormat.fromWireMode(LxmfFields.AM_OPUS_OGG))
        // Codec2 modes resolve 1:1.
        XCTAssertEqual(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CODEC2_1200), .codec2_1200)
        XCTAssertEqual(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CODEC2_2400), .codec2_2400)
        XCTAssertEqual(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CODEC2_3200), .codec2_3200)
    }

    // MARK: - Message init carries the attachment through

    func testMessageInitCarriesAudioAttachment() {
        let attachment = AudioAttachment(mode: .codec2_1200, bytes: Data([1, 1, 1]), durationMs: 500)
        let message = Message(id: "voice-1", content: "", isFromMe: true, audioAttachment: attachment)
        XCTAssertEqual(message.audioAttachment?.mode, .codec2_1200)
        XCTAssertEqual(message.audioAttachment?.bytes, Data([1, 1, 1]))
        XCTAssertEqual(message.audioAttachment?.durationMs, 500)
        // A text-only message has no audio.
        let plain = Message(id: "text-1", content: "hi", isFromMe: false)
        XCTAssertNil(plain.audioAttachment)
    }

    func testMessageFromLxMessageParsesAudioField() {
        let payload = Data([0x98, 0x11, 0x11])
        let lx = LXMessage(
            destinationHash: Data([0xAA, 0xBB]),
            sourceIdentity: nil,
            content: Data(),
            fields: [LxmfFields.FIELD_AUDIO: [Int(0x10), payload] as [Any]]
        )
        let message = Message(from: lx, localHash: Data([0x01]))
        XCTAssertEqual(message.audioAttachment?.mode, .opusOgg)
        XCTAssertEqual(message.audioAttachment?.bytes, payload)
    }

    func testMessageFromLxMessageWithoutAudioField() {
        let lx = LXMessage(
            destinationHash: Data([0xAA, 0xBB]),
            sourceIdentity: nil,
            content: Data("hello".utf8),
            fields: nil
        )
        let message = Message(from: lx, localHash: Data([0x01]))
        XCTAssertNil(message.audioAttachment)
    }

    // MARK: - Wire constants

    func testWireConstants() {
        XCTAssertEqual(LxmfFields.FIELD_AUDIO, 0x07)
        XCTAssertEqual(LxmfFields.AM_CODEC2_1200, 0x04)
        XCTAssertEqual(LxmfFields.AM_CODEC2_2400, 0x08)
        XCTAssertEqual(LxmfFields.AM_CODEC2_3200, 0x09)
        XCTAssertEqual(LxmfFields.AM_OPUS_OGG, 0x10)
        XCTAssertEqual(LxmfFields.AM_CUSTOM, 0xFF)
    }
}
