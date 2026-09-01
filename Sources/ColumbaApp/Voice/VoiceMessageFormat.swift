//
//  VoiceMessageFormat.swift
//  ColumbaApp
//
//  The six voice-message quality profiles, ported 1:1 from Android Columba's
//  `VoiceMessageFormat.kt` (the post-alignment table from PR #1098 - three
//  Codec2 + three Opus, "Medium Quality" as the default/recommended). The
//  display names and descriptions are localized; the EXACT English text must
//  match Android's `values/strings.xml` (enforced by
//  Tests/static/test_voice_messages.py).
//
//  NOTE: this is the VOICE-MESSAGE table, distinct from the voice-CALL
//  `CodecProfileInfo` (which has a different option set and link-probe-based
//  recommendation). Do not conflate them.
//

import Foundation
import SwiftUI
import RNSAPI
import LXSTSwift

/// A voice-message recording quality profile.
public enum VoiceMessageFormat: Int, CaseIterable, Identifiable, Sendable {
    case codec2_1200
    case codec2_2400
    case codec2_3200
    case opusMedium
    case opusHigh
    case opusMaximum

    public var id: Int { rawValue }

    /// The on-wire `FIELD_AUDIO` mode integer.
    public var wireMode: UInt8 {
        switch self {
        case .codec2_1200: return LxmfFields.AM_CODEC2_1200
        case .codec2_2400: return LxmfFields.AM_CODEC2_2400
        case .codec2_3200: return LxmfFields.AM_CODEC2_3200
        case .opusMedium, .opusHigh, .opusMaximum: return LxmfFields.AM_OPUS_OGG
        }
    }

    public var isCodec2: Bool {
        switch self {
        case .codec2_1200, .codec2_2400, .codec2_3200: return true
        case .opusMedium, .opusHigh, .opusMaximum: return false
        }
    }

    /// The `AudioMode` carried in the `FIELD_AUDIO` wire field.
    public var audioMode: AudioMode { AudioMode(wireValue: Int(wireMode))! }

    /// The LXST `Codec2Mode` for Codec2 profiles (nil for Opus).
    public var codec2Mode: Codec2Mode? {
        switch self {
        case .codec2_1200: return .codec2_1200
        case .codec2_2400: return .codec2_2400
        case .codec2_3200: return .codec2_3200
        case .opusMedium, .opusHigh, .opusMaximum: return nil
        }
    }

    /// The LXST `OpusProfile` for Opus profiles (nil for Codec2).
    /// Maps exactly to Android's `RecordingConfig` sample-rate/channel/bitrate
    /// table: medium 24k/mono/8k, high 48k/mono/16k, maximum 48k/stereo/32k.
    public var opusProfile: OpusProfile? {
        switch self {
        case .opusMedium: return .voiceMedium
        case .opusHigh: return .voiceHigh
        case .opusMaximum: return .voiceMax
        case .codec2_1200, .codec2_2400, .codec2_3200: return nil
        }
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .codec2_1200: return LocalizedStringResource("Codec2 1200")
        case .codec2_2400: return LocalizedStringResource("Codec2 2400")
        case .codec2_3200: return LocalizedStringResource("Codec2 3200")
        case .opusMedium: return LocalizedStringResource("Medium Quality")
        case .opusHigh: return LocalizedStringResource("High Quality")
        case .opusMaximum: return LocalizedStringResource("Maximum Quality")
        }
    }

    public var description: LocalizedStringResource {
        switch self {
        case .codec2_1200: return LocalizedStringResource("Very low bandwidth voice")
        case .codec2_2400: return LocalizedStringResource("Low bandwidth voice")
        case .codec2_3200: return LocalizedStringResource("Clearer speech at low bandwidth")
        case .opusMedium: return LocalizedStringResource("Opus 8 kbps mono - good balance of quality and bandwidth")
        case .opusHigh: return LocalizedStringResource("Opus 16 kbps mono - higher fidelity audio")
        case .opusMaximum: return LocalizedStringResource("Opus 32 kbps stereo - best audio, requires more bandwidth")
        }
    }

    /// Whether this profile is the recommended default (Medium Quality).
    public var isRecommended: Bool { self == Self.defaultFormat }

    public static let defaultFormat: VoiceMessageFormat = .opusMedium

    /// The outbound options shown in the quality picker, in display order
    /// (Codec2 1200 → Maximum Quality).
    public static let outboundOptions: [VoiceMessageFormat] = Array(Self.allCases)

    /// Resolve a profile from an on-wire `FIELD_AUDIO` mode. Codec2 maps
    /// 1:1; all Opus modes map to the profile whose rate/channels match is not
    /// recoverable from the wire mode alone (Opus does not encode its bitrate
    /// in the mode), so an inbound Opus message has no canonical profile -
    /// return nil and let playback use the mode only.
    public static func fromWireMode(_ wireMode: UInt8) -> VoiceMessageFormat? {
        switch wireMode {
        case LxmfFields.AM_CODEC2_1200: return .codec2_1200
        case LxmfFields.AM_CODEC2_2400: return .codec2_2400
        case LxmfFields.AM_CODEC2_3200: return .codec2_3200
        default: return nil
        }
    }
}
