//
//  CodecProfileInfo.swift
//  ColumbaApp
//
//  UI model wrapping TelephonyProfile for display in CodecSelectionSheet.
//  Provides descriptions, bandwidth estimates, and grouping for the picker.
//

import LXSTSwift

/// Display information for a telephony profile.
struct CodecProfileInfo: Identifiable {
    let profile: TelephonyProfile
    var id: UInt8 { profile.rawValue }

    var displayName: String { profile.displayName }

    var description: String {
        switch profile {
        case .bandwidthUltraLow:
            return "Codec2 700C, 400ms frames"
        case .bandwidthVeryLow:
            return "Codec2 1600, 320ms frames"
        case .bandwidthLow:
            return "Codec2 3200, 200ms frames"
        case .qualityMedium:
            return "Opus 24kHz, 60ms frames"
        case .qualityHigh:
            return "Opus 48kHz, 60ms frames"
        case .qualityMax:
            return "Opus 48kHz stereo, 60ms frames"
        case .latencyLow:
            return "Opus 24kHz, 20ms frames"
        case .latencyUltraLow:
            return "Opus 24kHz, 10ms frames"
        }
    }

    var bandwidthEstimate: String {
        switch profile {
        case .bandwidthUltraLow: return "~0.7 kbps"
        case .bandwidthVeryLow:  return "~1.6 kbps"
        case .bandwidthLow:      return "~3.2 kbps"
        case .qualityMedium:     return "~16 kbps"
        case .qualityHigh:       return "~32 kbps"
        case .qualityMax:        return "~64 kbps"
        case .latencyLow:        return "~16 kbps"
        case .latencyUltraLow:   return "~16 kbps"
        }
    }

    var icon: String {
        switch profile {
        case .bandwidthUltraLow, .bandwidthVeryLow, .bandwidthLow:
            return "antenna.radiowaves.left.and.right"
        case .qualityMedium, .qualityHigh, .qualityMax:
            return "waveform"
        case .latencyLow, .latencyUltraLow:
            return "bolt.fill"
        }
    }

    /// Group name for section headers.
    var group: String {
        switch profile {
        case .bandwidthUltraLow, .bandwidthVeryLow, .bandwidthLow:
            return "Bandwidth"
        case .qualityMedium, .qualityHigh, .qualityMax:
            return "Quality"
        case .latencyLow, .latencyUltraLow:
            return "Latency"
        }
    }

    /// All profiles grouped by category.
    static let grouped: [(section: String, profiles: [CodecProfileInfo])] = [
        ("Bandwidth", [
            CodecProfileInfo(profile: .bandwidthUltraLow),
            CodecProfileInfo(profile: .bandwidthVeryLow),
            CodecProfileInfo(profile: .bandwidthLow),
        ]),
        ("Quality", [
            CodecProfileInfo(profile: .qualityMedium),
            CodecProfileInfo(profile: .qualityHigh),
            CodecProfileInfo(profile: .qualityMax),
        ]),
        ("Latency", [
            CodecProfileInfo(profile: .latencyLow),
            CodecProfileInfo(profile: .latencyUltraLow),
        ]),
    ]
}
