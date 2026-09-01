//
//  AudioModeTests.swift
//  ColumbaAppTests
//
//  Phase A (plan step 5): wire-mode constants, the wire-vs-LXST Codec2 header
//  reconciliation, `fromWireValue` leniency, and the profile ->
//  (rate/channels/bitrate) table matching Android exactly.
//

import XCTest
import RNSAPI
import LXSTSwift
@testable import ColumbaApp

final class AudioModeTests: XCTestCase {

    // MARK: - Wire constants (Section 1)

    func testWireConstantsMatchAndroidAndUpstream() {
        XCTAssertEqual(LxmfFields.FIELD_AUDIO, 0x07)
        XCTAssertEqual(LxmfFields.AM_CODEC2_450PWB, 0x01)
        XCTAssertEqual(LxmfFields.AM_CODEC2_450, 0x02)
        XCTAssertEqual(LxmfFields.AM_CODEC2_700C, 0x03)
        XCTAssertEqual(LxmfFields.AM_CODEC2_1200, 0x04)
        XCTAssertEqual(LxmfFields.AM_CODEC2_1300, 0x05)
        XCTAssertEqual(LxmfFields.AM_CODEC2_1400, 0x06)
        XCTAssertEqual(LxmfFields.AM_CODEC2_1600, 0x07)
        XCTAssertEqual(LxmfFields.AM_CODEC2_2400, 0x08)
        XCTAssertEqual(LxmfFields.AM_CODEC2_3200, 0x09)
        XCTAssertEqual(LxmfFields.AM_OPUS_OGG, 0x10)
        XCTAssertEqual(LxmfFields.AM_CUSTOM, 0xFF)
        // App-layer enum must stay in lockstep with RNSAPI.
        XCTAssertEqual(AudioMode.codec2_1200.rawValue, LxmfFields.AM_CODEC2_1200)
        XCTAssertEqual(AudioMode.opusOgg.rawValue, LxmfFields.AM_OPUS_OGG)
        XCTAssertEqual(AudioMode.custom.rawValue, LxmfFields.AM_CUSTOM)
    }

    // MARK: - Wire <-> LXST header reconciliation (MUST NOT conflate)

    func testCodec2ModeMapsToLXSTHeaderByteByBitrate() {
        // Wire mode and LXST Codec2Mode header byte are DIFFERENT numbering.
        XCTAssertEqual(AudioMode.codec2_700C.codec2Mode, .codec2_700C)
        XCTAssertEqual(AudioMode.codec2_700C.codec2HeaderByte, 0x00)
        XCTAssertEqual(AudioMode.codec2_1200.codec2Mode, .codec2_1200)
        XCTAssertEqual(AudioMode.codec2_1200.codec2HeaderByte, 0x01)
        XCTAssertEqual(AudioMode.codec2_1300.codec2HeaderByte, 0x02)
        XCTAssertEqual(AudioMode.codec2_1400.codec2HeaderByte, 0x03)
        XCTAssertEqual(AudioMode.codec2_1600.codec2HeaderByte, 0x04)
        XCTAssertEqual(AudioMode.codec2_2400.codec2HeaderByte, 0x05)
        XCTAssertEqual(AudioMode.codec2_3200.codec2HeaderByte, 0x06)
        // 450/450PWB exist on the wire but LXST does not implement them.
        XCTAssertNil(AudioMode.codec2_450.codec2Mode)
        XCTAssertNil(AudioMode.codec2_450.codec2HeaderByte)
        XCTAssertNil(AudioMode.opusOgg.codec2Mode)
        XCTAssertNil(AudioMode.custom.codec2Mode)
    }

    func testCodec2Bitrates() {
        XCTAssertEqual(AudioMode.codec2_450PWB.codec2Bitrate, 450)
        XCTAssertEqual(AudioMode.codec2_700C.codec2Bitrate, 700)
        XCTAssertEqual(AudioMode.codec2_1200.codec2Bitrate, 1200)
        XCTAssertEqual(AudioMode.codec2_2400.codec2Bitrate, 2400)
        XCTAssertEqual(AudioMode.codec2_3200.codec2Bitrate, 3200)
        XCTAssertNil(AudioMode.opusOgg.codec2Bitrate)
        XCTAssertNil(AudioMode.custom.codec2Bitrate)
    }

    func testIsCodec2() {
        XCTAssertTrue(AudioMode.codec2_700C.isCodec2)
        XCTAssertTrue(AudioMode.codec2_1200.isCodec2)
        XCTAssertTrue(AudioMode.codec2_2400.isCodec2)
        XCTAssertTrue(AudioMode.codec2_3200.isCodec2)
        XCTAssertFalse(AudioMode.opusOgg.isCodec2)
        XCTAssertFalse(AudioMode.custom.isCodec2)
    }

    // MARK: - fromWireValue leniency

    func testWireValueInitAcceptsCanonicalValues() {
        XCTAssertEqual(AudioMode(wireValue: 0x03), .codec2_700C)
        XCTAssertEqual(AudioMode(wireValue: 0x08), .codec2_2400)
        XCTAssertEqual(AudioMode(wireValue: 0x10), .opusOgg)
        XCTAssertEqual(AudioMode(wireValue: 0xFF), .custom)
    }

    func testWireValueInitMapsUnknownToCustom() {
        // Non-canonical bytes must render as .custom (non-playable), not nil.
        XCTAssertEqual(AudioMode(wireValue: 0x00), .custom)
        XCTAssertEqual(AudioMode(wireValue: 0x11), .custom)
        XCTAssertEqual(AudioMode(wireValue: 0x7F), .custom)
    }

    func testAttachmentFromWireValueAcceptsIntegerTypesAndData() {
        let payload = Data([1, 2, 3, 4])
        let fromInt = AudioAttachment.fromWireValue([Int(0x04), payload])
        XCTAssertEqual(fromInt?.mode, .codec2_1200)
        XCTAssertEqual(fromInt?.bytes, payload)

        let fromUInt8 = AudioAttachment.fromWireValue([UInt8(0x10), payload])
        XCTAssertEqual(fromUInt8?.mode, .opusOgg)

        let fromInt32 = AudioAttachment.fromWireValue([Int32(0x08), payload])
        XCTAssertEqual(fromInt32?.mode, .codec2_2400)
    }

    func testAttachmentFromWireValueRejectsBadShapes() {
        XCTAssertNil(AudioAttachment.fromWireValue(nil))
        XCTAssertNil(AudioAttachment.fromWireValue([Int(0x04)]))              // too short
        XCTAssertNil(AudioAttachment.fromWireValue(["x", Data([1])] as [Any])) // mode not int
        XCTAssertNil(AudioAttachment.fromWireValue([Int(0x04), "bytes"]))      // payload not Data
        XCTAssertEqual(AudioAttachment.fromWireValue([Int(0x11), Data([1])])?.mode, .custom)
    }

    func testAttachmentFieldValueRoundTrip() {
        let payload = Data([9, 8, 7])
        let attachment = AudioAttachment(mode: .codec2_2400, bytes: payload, durationMs: 1234)
        XCTAssertEqual(attachment.sizeBytes, 3)
        XCTAssertEqual(attachment.durationSeconds, 1.234, accuracy: 0.0001)
        let field = attachment.fieldValue
        let mode = (field[0] as? Int) ?? Int((field[0] as? UInt8) ?? 0)
        XCTAssertEqual(mode, 0x08)
        XCTAssertEqual(field[1] as? Data, payload)
        let back = AudioAttachment.fromWireValue(field)
        XCTAssertEqual(back?.mode, .codec2_2400)
        XCTAssertEqual(back?.bytes, payload)
        // durationMs is best-effort and NOT carried on the wire.
        XCTAssertNil(back?.durationMs)
    }

    func testZeroDurationSeconds() {
        XCTAssertEqual(AudioAttachment(mode: .opusOgg, bytes: Data(), durationMs: nil).durationSeconds, 0)
        XCTAssertEqual(AudioAttachment(mode: .opusOgg, bytes: Data(), durationMs: 0).durationSeconds, 0)
    }
}
