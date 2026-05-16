// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Torlando Tech LLC
//
//
//  LXSTConstants.swift
//  LXSTSwift
//
//  Protocol constants matching Python LXST for wire interop.
//

import Foundation

// MARK: - Wire Format Fields (Network.py)

/// Msgpack dictionary keys for packet fields.
public enum LXSTField {
    /// Signalling field key in msgpack dict. Python Network.py:10
    public static let signalling: UInt8 = 0x00
    /// Audio frames field key in msgpack dict. Python Network.py:11
    public static let frames: UInt8 = 0x01
}

// MARK: - Codec Type Headers (Codecs/__init__.py)

/// Codec type header bytes prepended to encoded audio data.
public enum LXSTCodecType: UInt8, Sendable, CaseIterable {
    /// Null/passthrough codec. Python Codecs/__init__.py:8
    case null   = 0xFF
    /// Raw PCM codec. Python Codecs/__init__.py:9
    case raw    = 0x00
    /// Opus codec. Python Codecs/__init__.py:10
    case opus   = 0x01
    /// Codec2 codec. Python Codecs/__init__.py:11
    case codec2 = 0x02
}

// MARK: - Codec2 Mode Headers (Codecs/Codec2.py:25-31)

/// Codec2 mode header bytes.
public enum Codec2Mode: UInt8, Sendable, CaseIterable {
    case codec2_700C = 0x00
    case codec2_1200 = 0x01
    case codec2_1300 = 0x02
    case codec2_1400 = 0x03
    case codec2_1600 = 0x04
    case codec2_2400 = 0x05
    case codec2_3200 = 0x06

    /// Codec2 bitrate for this mode.
    public var bitrate: Int {
        switch self {
        case .codec2_700C: return 700
        case .codec2_1200: return 1200
        case .codec2_1300: return 1300
        case .codec2_1400: return 1400
        case .codec2_1600: return 1600
        case .codec2_2400: return 2400
        case .codec2_3200: return 3200
        }
    }

    /// Codec2 always operates at 8000 Hz.
    public static let inputRate: Int = 8000
    public static let outputRate: Int = 8000
}

// MARK: - Opus Profiles (Codecs/Opus.py:15-23)

/// Opus codec profile bytes.
public enum OpusProfile: UInt8, Sendable, CaseIterable {
    case voiceLow    = 0x00
    case voiceMedium = 0x01
    case voiceHigh   = 0x02
    case voiceMax    = 0x03
    case audioMin    = 0x04
    case audioLow    = 0x05
    case audioMedium = 0x06
    case audioHigh   = 0x07
    case audioMax    = 0x08

    /// Sample rate for this profile. Python Opus.py:54-63
    public var sampleRate: Int {
        switch self {
        case .voiceLow:    return 8000
        case .voiceMedium: return 24000
        case .voiceHigh:   return 48000
        case .voiceMax:    return 48000
        case .audioMin:    return 8000
        case .audioLow:    return 12000
        case .audioMedium: return 24000
        case .audioHigh:   return 48000
        case .audioMax:    return 48000
        }
    }

    /// Number of channels. Python Opus.py:44-53
    public var channels: Int {
        switch self {
        case .voiceLow:    return 1
        case .voiceMedium: return 1
        case .voiceHigh:   return 1
        case .voiceMax:    return 2
        case .audioMin:    return 1
        case .audioLow:    return 1
        case .audioMedium: return 2
        case .audioHigh:   return 2
        case .audioMax:    return 2
        }
    }

    /// Opus application type. Python Opus.py:65-74
    public var application: String {
        switch self {
        case .voiceLow, .voiceMedium, .voiceHigh, .voiceMax:
            return "voip"
        case .audioMin, .audioLow, .audioMedium, .audioHigh, .audioMax:
            return "audio"
        }
    }

    /// Maximum bitrate ceiling in bps. Python Opus.py:76-85
    public var bitrateCeiling: Int {
        switch self {
        case .voiceLow:    return 6000
        case .voiceMedium: return 8000
        case .voiceHigh:   return 16000
        case .voiceMax:    return 32000
        case .audioMin:    return 8000
        case .audioLow:    return 14000
        case .audioMedium: return 28000
        case .audioHigh:   return 56000
        case .audioMax:    return 128000
        }
    }

    /// Max encoded bytes per frame. Python Opus.py:96-97
    public func maxBytesPerFrame(frameDurationMs: Double) -> Int {
        Int(ceil(Double(bitrateCeiling) / 8.0 * frameDurationMs / 1000.0))
    }
}

// MARK: - Signalling Codes (Primitives/Telephony.py:102-110)

/// Call signalling status codes sent over the link.
public enum LXSTSignal: UInt8, Sendable, CaseIterable {
    case busy        = 0x00
    case rejected    = 0x01
    case calling     = 0x02
    case available   = 0x03
    case ringing     = 0x04
    case connecting  = 0x05
    case established = 0x06

    /// Preferred profile signal marker. Python Telephony.py:110
    public static let preferredProfile: UInt8 = 0xFF

    /// Auto-status codes that are part of normal call flow.
    public static let autoStatusCodes: [LXSTSignal] = [
        .calling, .available, .ringing, .connecting, .established
    ]
}

// MARK: - Telephony Profiles (Primitives/Telephony.py:19-28)

/// Telephony profile bytes controlling codec selection and frame timing.
public enum TelephonyProfile: UInt8, Sendable, CaseIterable {
    case bandwidthUltraLow = 0x10
    case bandwidthVeryLow  = 0x20
    case bandwidthLow      = 0x30
    case qualityMedium     = 0x40
    case qualityHigh       = 0x50
    case qualityMax        = 0x60
    case latencyLow        = 0x70
    case latencyUltraLow   = 0x80

    public static let defaultProfile: TelephonyProfile = .qualityMedium

    /// Codec for this profile. Python Telephony.py:72-81
    public var codecType: LXSTCodecType {
        switch self {
        case .bandwidthUltraLow, .bandwidthVeryLow, .bandwidthLow:
            return .codec2
        default:
            return .opus
        }
    }

    /// Codec2 mode for bandwidth profiles. Nil for Opus profiles.
    public var codec2Mode: Codec2Mode? {
        switch self {
        case .bandwidthUltraLow: return .codec2_700C
        case .bandwidthVeryLow:  return .codec2_1600
        case .bandwidthLow:      return .codec2_3200
        default: return nil
        }
    }

    /// Opus profile for quality/latency profiles. Nil for Codec2 profiles.
    public var opusProfile: OpusProfile? {
        switch self {
        case .qualityMedium:    return .voiceMedium
        case .qualityHigh:      return .voiceHigh
        case .qualityMax:       return .voiceMax
        case .latencyLow:       return .voiceMedium
        case .latencyUltraLow:  return .voiceMedium
        default: return nil
        }
    }

    /// Frame time in milliseconds. Python Telephony.py:84-93
    public var frameTimeMs: Int {
        switch self {
        case .bandwidthUltraLow: return 400
        case .bandwidthVeryLow:  return 320
        case .bandwidthLow:      return 200
        case .qualityMedium:     return 60
        case .qualityHigh:       return 60
        case .qualityMax:        return 60
        case .latencyLow:        return 20
        case .latencyUltraLow:   return 10
        }
    }

    /// Human-readable profile name.
    public var displayName: String {
        switch self {
        case .bandwidthUltraLow: return "Ultra Low Bandwidth"
        case .bandwidthVeryLow:  return "Very Low Bandwidth"
        case .bandwidthLow:      return "Low Bandwidth"
        case .qualityMedium:     return "Medium Quality"
        case .qualityHigh:       return "High Quality"
        case .qualityMax:        return "Super High Quality"
        case .latencyLow:        return "Low Latency"
        case .latencyUltraLow:   return "Ultra Low Latency"
        }
    }

    /// Short abbreviation. Python Telephony.py:60-69
    public var abbreviation: String {
        switch self {
        case .bandwidthUltraLow: return "ULBW"
        case .bandwidthVeryLow:  return "VLBW"
        case .bandwidthLow:      return "LBW"
        case .qualityMedium:     return "MQ"
        case .qualityHigh:       return "HQ"
        case .qualityMax:        return "SHQ"
        case .latencyLow:        return "LL"
        case .latencyUltraLow:   return "ULL"
        }
    }

    /// Next profile in rotation. Python Telephony.py:96-100
    public var nextProfile: TelephonyProfile {
        let all = TelephonyProfile.allCases
        guard let idx = all.firstIndex(of: self) else { return .qualityMedium }
        return all[(idx + 1) % all.count]
    }
}

// MARK: - Telephony Constants (Primitives/Telephony.py:115-123)

/// Timing and configuration constants for the Telephone actor.
public enum TelephonyConstants {
    /// App name for RNS destination. Python __init__.py:1
    public static let appName = "lxst"
    /// Aspect for telephony destination. Python Telephony.py:17
    public static let primitiveName = "telephony"

    /// Ring timeout in seconds. Python Telephony.py:115
    public static let ringTime: TimeInterval = 60
    /// Wait timeout for callee response. Python Telephony.py:116
    public static let waitTime: TimeInterval = 70
    /// Connect timeout. Python Telephony.py:117
    public static let connectTime: TimeInterval = 5
    /// Dial tone frequency in Hz. Python Telephony.py:118
    public static let dialToneFrequency: Double = 382
    /// Dial tone ease-in in ms. Python Telephony.py:119
    public static let dialToneEaseMs: Double = 3.14159
    /// Background job interval. Python Telephony.py:120
    public static let jobInterval: TimeInterval = 5

    /// Allow all callers. Python Telephony.py:123
    public static let allowAll: UInt8 = 0xFF
    /// Allow no callers. Python Telephony.py:124
    public static let allowNone: UInt8 = 0xFE
}
