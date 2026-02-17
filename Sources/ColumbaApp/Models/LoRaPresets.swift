//
//  LoRaPresets.swift
//  ColumbaApp
//
//  Regional and modem preset lookup tables for RNode LoRa configuration.
//  Provides frequency parameters for all ITU regions worldwide plus
//  community-tested city presets.
//

import Foundation

// MARK: - Regional Parameters

/// Regional LoRa frequency parameters.
///
/// Defines band edges, center frequency, and regulatory limits for ISM bands.
@available(iOS 17.0, macOS 14.0, *)
public struct RegionalParameters {
    /// Band start frequency in Hz.
    public let freqStart: UInt32

    /// Band end frequency in Hz.
    public let freqEnd: UInt32

    /// Maximum transmit power in dBm (regulatory limit).
    public let maxTxPower: UInt8

    /// Duty cycle limit (e.g. 0.01 = 1%). Nil means no restriction.
    public let dutyCycle: Double?

    /// Default center frequency in Hz (midpoint of band).
    public var frequency: UInt32 { (freqStart + freqEnd) / 2 }

    /// Minimum allowed frequency (alias for freqStart).
    public var minFreq: UInt32 { freqStart }

    /// Maximum allowed frequency (alias for freqEnd).
    public var maxFreq: UInt32 { freqEnd }

    /// Number of available frequency slots for a given bandwidth.
    public func totalSlots(bandwidth: UInt32) -> Int {
        guard bandwidth > 0 else { return 0 }
        return Int((freqEnd - freqStart) / bandwidth)
    }

    /// Calculate the center frequency for a given slot and bandwidth.
    public func slotFrequency(slot: Int, bandwidth: UInt32) -> UInt32 {
        freqStart + (bandwidth / 2) + UInt32(slot) * bandwidth
    }
}

// MARK: - LoRa Region

/// Regional LoRa frequency presets matching ITU allocations worldwide.
///
/// Covers 21 frequency regions including multiple EU 868 sub-bands.
/// Used by the RNode configuration wizard for region selection.
@available(iOS 17.0, macOS 14.0, *)
public enum LoRaRegion: String, CaseIterable, Identifiable {
    case us915 = "US 915 MHz"
    case eu868Low = "EU 863–868 MHz"
    case eu868Mid = "EU 868–868.6 MHz"
    case eu868Primary = "EU 867–869.2 MHz"
    case eu868QBand = "EU 869.4–869.65 MHz"
    case eu433 = "EU 433 MHz"
    case ru868 = "RU 868 MHz"
    case ua868 = "UA 868 MHz"
    case au915 = "AU 915 MHz"
    case nz865 = "NZ 865 MHz"
    case jp920 = "JP 920 MHz"
    case kr920 = "KR 920 MHz"
    case tw920 = "TW 920 MHz"
    case cn470 = "CN 470 MHz"
    case in865 = "IN 865 MHz"
    case th920 = "TH 920 MHz"
    case sg923 = "SG 923 MHz"
    case my919 = "MY 919 MHz"
    case ph915 = "PH 915 MHz"
    case lora24 = "LoRa 2.4 GHz"
    case br902 = "BR 902 MHz"

    public var id: String { rawValue }

    /// Emoji flag for the region's country.
    public var countryFlag: String {
        switch self {
        case .us915: return "🇺🇸"
        case .eu868Low, .eu868Mid, .eu868Primary, .eu868QBand, .eu433: return "🇪🇺"
        case .ru868: return "🇷🇺"
        case .ua868: return "🇺🇦"
        case .au915: return "🇦🇺"
        case .nz865: return "🇳🇿"
        case .jp920: return "🇯🇵"
        case .kr920: return "🇰🇷"
        case .tw920: return "🇹🇼"
        case .cn470: return "🇨🇳"
        case .in865: return "🇮🇳"
        case .th920: return "🇹🇭"
        case .sg923: return "🇸🇬"
        case .my919: return "🇲🇾"
        case .ph915: return "🇵🇭"
        case .lora24: return "🌐"
        case .br902: return "🇧🇷"
        }
    }

    /// Continent grouping for the region picker.
    public var continent: String {
        switch self {
        case .us915, .br902: return "Americas"
        case .eu868Low, .eu868Mid, .eu868Primary, .eu868QBand, .eu433,
             .ru868, .ua868: return "Europe"
        case .au915, .nz865, .jp920, .kr920, .tw920, .cn470,
             .in865, .th920, .sg923, .my919, .ph915: return "Asia-Pacific"
        case .lora24: return "Global"
        }
    }

    /// Short label for compact display.
    public var shortName: String {
        switch self {
        case .us915: return "US 915"
        case .eu868Low: return "EU 868 Low"
        case .eu868Mid: return "EU 868 Mid"
        case .eu868Primary: return "EU 868"
        case .eu868QBand: return "EU 869 HP"
        case .eu433: return "EU 433"
        case .ru868: return "RU 868"
        case .ua868: return "UA 868"
        case .au915: return "AU 915"
        case .nz865: return "NZ 865"
        case .jp920: return "JP 920"
        case .kr920: return "KR 920"
        case .tw920: return "TW 920"
        case .cn470: return "CN 470"
        case .in865: return "IN 865"
        case .th920: return "TH 920"
        case .sg923: return "SG 923"
        case .my919: return "MY 919"
        case .ph915: return "PH 915"
        case .lora24: return "2.4 GHz"
        case .br902: return "BR 902"
        }
    }

    /// Get the regional parameters for this region.
    public var parameters: RegionalParameters {
        switch self {
        case .us915:
            return RegionalParameters(freqStart: 902_000_000, freqEnd: 928_000_000, maxTxPower: 30, dutyCycle: nil)
        case .eu868Low:
            return RegionalParameters(freqStart: 863_000_000, freqEnd: 868_000_000, maxTxPower: 14, dutyCycle: 0.001)
        case .eu868Mid:
            return RegionalParameters(freqStart: 868_000_000, freqEnd: 868_600_000, maxTxPower: 14, dutyCycle: 0.01)
        case .eu868Primary:
            return RegionalParameters(freqStart: 867_000_000, freqEnd: 869_200_000, maxTxPower: 14, dutyCycle: 0.01)
        case .eu868QBand:
            return RegionalParameters(freqStart: 869_400_000, freqEnd: 869_650_000, maxTxPower: 27, dutyCycle: 0.10)
        case .eu433:
            return RegionalParameters(freqStart: 433_050_000, freqEnd: 434_790_000, maxTxPower: 12, dutyCycle: 0.10)
        case .ru868:
            return RegionalParameters(freqStart: 864_000_000, freqEnd: 869_200_000, maxTxPower: 20, dutyCycle: nil)
        case .ua868:
            return RegionalParameters(freqStart: 863_000_000, freqEnd: 870_000_000, maxTxPower: 14, dutyCycle: nil)
        case .au915:
            return RegionalParameters(freqStart: 915_000_000, freqEnd: 928_000_000, maxTxPower: 30, dutyCycle: nil)
        case .nz865:
            return RegionalParameters(freqStart: 864_000_000, freqEnd: 868_000_000, maxTxPower: 27, dutyCycle: nil)
        case .jp920:
            return RegionalParameters(freqStart: 920_000_000, freqEnd: 928_000_000, maxTxPower: 13, dutyCycle: nil)
        case .kr920:
            return RegionalParameters(freqStart: 920_900_000, freqEnd: 923_300_000, maxTxPower: 14, dutyCycle: nil)
        case .tw920:
            return RegionalParameters(freqStart: 920_000_000, freqEnd: 925_000_000, maxTxPower: 14, dutyCycle: nil)
        case .cn470:
            return RegionalParameters(freqStart: 470_000_000, freqEnd: 510_000_000, maxTxPower: 19, dutyCycle: nil)
        case .in865:
            return RegionalParameters(freqStart: 865_000_000, freqEnd: 867_000_000, maxTxPower: 30, dutyCycle: nil)
        case .th920:
            return RegionalParameters(freqStart: 920_000_000, freqEnd: 925_000_000, maxTxPower: 27, dutyCycle: nil)
        case .sg923:
            return RegionalParameters(freqStart: 920_000_000, freqEnd: 925_000_000, maxTxPower: 20, dutyCycle: nil)
        case .my919:
            return RegionalParameters(freqStart: 919_000_000, freqEnd: 923_000_000, maxTxPower: 27, dutyCycle: nil)
        case .ph915:
            return RegionalParameters(freqStart: 915_000_000, freqEnd: 918_000_000, maxTxPower: 21, dutyCycle: nil)
        case .lora24:
            return RegionalParameters(freqStart: 2_400_000_000, freqEnd: 2_500_000_000, maxTxPower: 10, dutyCycle: nil)
        case .br902:
            return RegionalParameters(freqStart: 902_000_000, freqEnd: 907_500_000, maxTxPower: 30, dutyCycle: nil)
        }
    }

    /// Regions grouped by continent for the picker UI.
    public static var byContinent: [(String, [LoRaRegion])] {
        let grouped = Dictionary(grouping: allCases, by: \.continent)
        let order = ["Americas", "Europe", "Asia-Pacific", "Global"]
        return order.compactMap { continent in
            guard let regions = grouped[continent] else { return nil }
            return (continent, regions)
        }
    }

    /// Meshtastic default frequency for this region (approximate, for conflict detection).
    public var meshtasticDefaultFrequency: UInt32? {
        switch self {
        case .us915: return 906_875_000
        case .eu868Primary, .eu868Low, .eu868Mid: return 869_525_000
        case .au915: return 916_000_000
        case .jp920: return 927_000_000
        case .kr920: return 922_000_000
        case .cn470: return 490_000_000
        case .in865: return 866_000_000
        case .br902: return 906_875_000
        default: return nil
        }
    }
}

/// Backward compatibility alias.
@available(iOS 17.0, macOS 14.0, *)
public typealias RegionalPreset = LoRaRegion

// MARK: - Modem Parameters

/// Modem configuration parameters for LoRa modulation.
///
/// Defines bandwidth, spreading factor, and coding rate.
@available(iOS 17.0, macOS 14.0, *)
public struct ModemParameters {
    /// Bandwidth in Hz.
    public let bandwidth: UInt32

    /// Spreading factor (7-12).
    public let spreadingFactor: UInt8

    /// Coding rate (5-8, represents 4/5 to 4/8).
    public let codingRate: UInt8
}

// MARK: - Modem Preset

/// Modem presets matching Meshtastic configuration.
///
/// Provides pre-configured combinations of bandwidth, spreading factor,
/// and coding rate for different range/speed tradeoffs.
@available(iOS 17.0, macOS 14.0, *)
public enum ModemPreset: String, CaseIterable, Identifiable {
    case shortTurbo = "Short Turbo"
    case shortFast = "Short Fast"
    case shortSlow = "Short Slow"
    case mediumFast = "Medium Fast"
    case mediumSlow = "Medium Slow"
    case longFast = "Long Fast"
    case longModerate = "Long Moderate"
    case longSlow = "Long Slow"

    public var id: String { rawValue }

    /// Whether this is the recommended default preset.
    public var isRecommended: Bool { self == .longFast }

    /// Short description of the tradeoff.
    public var subtitle: String {
        switch self {
        case .shortTurbo: return "Fastest speed, shortest range"
        case .shortFast: return "High speed, short range"
        case .shortSlow: return "Moderate speed, short range"
        case .mediumFast: return "Balanced speed and range"
        case .mediumSlow: return "Lower speed, medium range"
        case .longFast: return "Good range with usable speed"
        case .longModerate: return "Long range, moderate speed"
        case .longSlow: return "Maximum range, lowest speed"
        }
    }

    /// Technical specs string for display.
    public var specsString: String {
        let p = parameters
        return "SF\(p.spreadingFactor) / BW \(p.bandwidth / 1000) kHz / CR 4/\(p.codingRate)"
    }

    /// Get the modem parameters for this preset.
    public var parameters: ModemParameters {
        switch self {
        case .shortTurbo:
            return ModemParameters(bandwidth: 500_000, spreadingFactor: 7, codingRate: 5)
        case .shortFast:
            return ModemParameters(bandwidth: 250_000, spreadingFactor: 7, codingRate: 5)
        case .shortSlow:
            return ModemParameters(bandwidth: 250_000, spreadingFactor: 8, codingRate: 5)
        case .mediumFast:
            return ModemParameters(bandwidth: 250_000, spreadingFactor: 9, codingRate: 5)
        case .mediumSlow:
            return ModemParameters(bandwidth: 250_000, spreadingFactor: 10, codingRate: 5)
        case .longFast:
            return ModemParameters(bandwidth: 250_000, spreadingFactor: 11, codingRate: 5)
        case .longModerate:
            return ModemParameters(bandwidth: 125_000, spreadingFactor: 11, codingRate: 8)
        case .longSlow:
            return ModemParameters(bandwidth: 125_000, spreadingFactor: 12, codingRate: 8)
        }
    }
}

// MARK: - Community Preset

/// A community-tested city frequency preset.
///
/// Provides pre-configured region + modem + slot combinations
/// that have been tested by community members in specific locations.
@available(iOS 17.0, macOS 14.0, *)
public struct CommunityPreset: Identifiable {
    public var id: String { name }
    public let name: String
    public let country: String
    public let region: LoRaRegion
    public let modemPreset: ModemPreset
    public let frequencySlot: Int

    /// Calculated frequency for this preset.
    public var frequency: UInt32 {
        region.parameters.slotFrequency(
            slot: frequencySlot,
            bandwidth: modemPreset.parameters.bandwidth
        )
    }

    /// All community presets grouped by country.
    public static var byCountry: [(String, [CommunityPreset])] {
        let grouped = Dictionary(grouping: presets, by: \.country)
        return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Community-tested presets.
    public static let presets: [CommunityPreset] = [
        // Americas
        CommunityPreset(name: "New York, USA", country: "United States", region: .us915, modemPreset: .longFast, frequencySlot: 52),
        CommunityPreset(name: "San Francisco, USA", country: "United States", region: .us915, modemPreset: .longFast, frequencySlot: 48),
        CommunityPreset(name: "Seattle, USA", country: "United States", region: .us915, modemPreset: .longFast, frequencySlot: 44),
        CommunityPreset(name: "Denver, USA", country: "United States", region: .us915, modemPreset: .longFast, frequencySlot: 40),
        CommunityPreset(name: "Toronto, Canada", country: "Canada", region: .us915, modemPreset: .longFast, frequencySlot: 36),
        CommunityPreset(name: "São Paulo, Brazil", country: "Brazil", region: .br902, modemPreset: .longFast, frequencySlot: 10),
        CommunityPreset(name: "Mexico City, Mexico", country: "Mexico", region: .us915, modemPreset: .longFast, frequencySlot: 32),

        // Europe
        CommunityPreset(name: "London, UK", country: "United Kingdom", region: .eu868Primary, modemPreset: .longFast, frequencySlot: 4),
        CommunityPreset(name: "Berlin, Germany", country: "Germany", region: .eu868Primary, modemPreset: .longFast, frequencySlot: 5),
        CommunityPreset(name: "Amsterdam, Netherlands", country: "Netherlands", region: .eu868Primary, modemPreset: .longFast, frequencySlot: 3),
        CommunityPreset(name: "Paris, France", country: "France", region: .eu868Primary, modemPreset: .longFast, frequencySlot: 6),
        CommunityPreset(name: "Stockholm, Sweden", country: "Sweden", region: .eu868Primary, modemPreset: .longFast, frequencySlot: 7),
        CommunityPreset(name: "Vienna, Austria", country: "Austria", region: .eu868Primary, modemPreset: .longFast, frequencySlot: 4),
        CommunityPreset(name: "Moscow, Russia", country: "Russia", region: .ru868, modemPreset: .longFast, frequencySlot: 10),
        CommunityPreset(name: "Kyiv, Ukraine", country: "Ukraine", region: .ua868, modemPreset: .longFast, frequencySlot: 12),

        // Asia-Pacific
        CommunityPreset(name: "Tokyo, Japan", country: "Japan", region: .jp920, modemPreset: .longFast, frequencySlot: 16),
        CommunityPreset(name: "Seoul, South Korea", country: "South Korea", region: .kr920, modemPreset: .longFast, frequencySlot: 4),
        CommunityPreset(name: "Taipei, Taiwan", country: "Taiwan", region: .tw920, modemPreset: .longFast, frequencySlot: 10),
        CommunityPreset(name: "Mumbai, India", country: "India", region: .in865, modemPreset: .longFast, frequencySlot: 4),
        CommunityPreset(name: "Bangkok, Thailand", country: "Thailand", region: .th920, modemPreset: .longFast, frequencySlot: 10),
        CommunityPreset(name: "Singapore", country: "Singapore", region: .sg923, modemPreset: .longFast, frequencySlot: 10),
        CommunityPreset(name: "Sydney, Australia", country: "Australia", region: .au915, modemPreset: .longFast, frequencySlot: 26),
        CommunityPreset(name: "Auckland, New Zealand", country: "New Zealand", region: .nz865, modemPreset: .longFast, frequencySlot: 8),
    ]
}
