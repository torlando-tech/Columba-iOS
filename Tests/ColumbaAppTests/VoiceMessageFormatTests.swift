//
//  VoiceMessageFormatTests.swift
//  ColumbaAppTests
//
//  Phase A (plan step 5): the six quality profiles map 1:1 to Android's
//  rate/channel/bitrate table; Medium Quality is the recommended default;
//  inbound Opus has no recoverable profile.
//

import XCTest
import RNSAPI
import LXSTSwift
@testable import ColumbaApp

final class VoiceMessageFormatTests: XCTestCase {

    func testOutboundOrderMatchesAndroid() {
        XCTAssertEqual(VoiceMessageFormat.outboundOptions,
                       [.codec2_1200, .codec2_2400, .codec2_3200,
                        .opusMedium, .opusHigh, .opusMaximum])
        XCTAssertEqual(VoiceMessageFormat.allCases.count, 6)
    }

    func testDefaultIsMediumAndRecommended() {
        XCTAssertEqual(VoiceMessageFormat.defaultFormat, .opusMedium)
        XCTAssertTrue(VoiceMessageFormat.opusMedium.isRecommended)
        XCTAssertFalse(VoiceMessageFormat.codec2_1200.isRecommended)
        XCTAssertFalse(VoiceMessageFormat.opusMaximum.isRecommended)
    }

    func testWireModes() {
        XCTAssertEqual(VoiceMessageFormat.codec2_1200.wireMode, LxmfFields.AM_CODEC2_1200)
        XCTAssertEqual(VoiceMessageFormat.codec2_2400.wireMode, LxmfFields.AM_CODEC2_2400)
        XCTAssertEqual(VoiceMessageFormat.codec2_3200.wireMode, LxmfFields.AM_CODEC2_3200)
        XCTAssertEqual(VoiceMessageFormat.opusMedium.wireMode, LxmfFields.AM_OPUS_OGG)
        XCTAssertEqual(VoiceMessageFormat.opusHigh.wireMode, LxmfFields.AM_OPUS_OGG)
        XCTAssertEqual(VoiceMessageFormat.opusMaximum.wireMode, LxmfFields.AM_OPUS_OGG)
    }

    func testCodec2ProfilesMapToAudioModeAndCodec2Mode() {
        XCTAssertEqual(VoiceMessageFormat.codec2_1200.audioMode, .codec2_1200)
        XCTAssertEqual(VoiceMessageFormat.codec2_2400.audioMode, .codec2_2400)
        XCTAssertEqual(VoiceMessageFormat.codec2_3200.audioMode, .codec2_3200)
        XCTAssertEqual(VoiceMessageFormat.codec2_1200.codec2Mode, .codec2_1200)
        XCTAssertEqual(VoiceMessageFormat.codec2_2400.codec2Mode, .codec2_2400)
        XCTAssertEqual(VoiceMessageFormat.codec2_3200.codec2Mode, .codec2_3200)
        XCTAssertTrue(VoiceMessageFormat.codec2_1200.isCodec2)
        XCTAssertFalse(VoiceMessageFormat.opusMedium.isCodec2)
    }

    func testOpusProfilesMatchAndroidRateChannelBitrateTable() {
        // Android RecordingConfig: medium 24k/mono/8k, high 48k/mono/16k,
        // maximum 48k/stereo/32k.
        let medium = VoiceMessageFormat.opusMedium.opusProfile
        XCTAssertEqual(medium, .voiceMedium)
        XCTAssertEqual(medium?.sampleRate, 24_000)
        XCTAssertEqual(medium?.channels, 1)
        XCTAssertEqual(medium?.bitrateCeiling, 8_000)

        let high = VoiceMessageFormat.opusHigh.opusProfile
        XCTAssertEqual(high, .voiceHigh)
        XCTAssertEqual(high?.sampleRate, 48_000)
        XCTAssertEqual(high?.channels, 1)
        XCTAssertEqual(high?.bitrateCeiling, 16_000)

        let max = VoiceMessageFormat.opusMaximum.opusProfile
        XCTAssertEqual(max, .voiceMax)
        XCTAssertEqual(max?.sampleRate, 48_000)
        XCTAssertEqual(max?.channels, 2)
        XCTAssertEqual(max?.bitrateCeiling, 32_000)

        // All three carry the same wire mode (bitrate is not on the wire).
        XCTAssertEqual(VoiceMessageFormat.opusMedium.audioMode, .opusOgg)
        XCTAssertEqual(VoiceMessageFormat.opusHigh.audioMode, .opusOgg)
        XCTAssertEqual(VoiceMessageFormat.opusMaximum.audioMode, .opusOgg)
    }

    func testFromWireModeResolvesCodec2Only() {
        XCTAssertEqual(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CODEC2_1200), .codec2_1200)
        XCTAssertEqual(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CODEC2_2400), .codec2_2400)
        XCTAssertEqual(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CODEC2_3200), .codec2_3200)
        // Opus bitrate is not recoverable from the wire mode -> no profile.
        XCTAssertNil(VoiceMessageFormat.fromWireMode(LxmfFields.AM_OPUS_OGG))
        // 1300/1400/1600 are valid wire modes but not voice-message profiles.
        XCTAssertNil(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CODEC2_1300))
        XCTAssertNil(VoiceMessageFormat.fromWireMode(LxmfFields.AM_CUSTOM))
        XCTAssertNil(VoiceMessageFormat.fromWireMode(0x20))
    }

    func testIdentifiableAndHashable() {
        XCTAssertEqual(VoiceMessageFormat.codec2_1200.id, VoiceMessageFormat.codec2_1200.rawValue)
        let set: Set<VoiceMessageFormat> = Set(VoiceMessageFormat.outboundOptions)
        XCTAssertEqual(set.count, 6)
    }
}
