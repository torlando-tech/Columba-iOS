//
//  LoRaPresets.swift
//  ColumbaApp
//
//  Regional and modem preset lookup tables for RNode LoRa configuration.
//  Provides Meshtastic-compatible parameter values for all presets.
//

import Foundation

// MARK: - Regional Parameters

/// Regional LoRa frequency parameters.
///
/// Defines center frequency and regulatory limits for common ISM bands.
@available(iOS 17.0, macOS 14.0, *)
public struct RegionalParameters {
    /// Center frequency in Hz.
    public let frequency: UInt32

    /// Minimum allowed frequency in Hz (regulatory limit).
    public let minFreq: UInt32

    /// Maximum allowed frequency in Hz (regulatory limit).
    public let maxFreq: UInt32

    /// Maximum transmit power in dBm (regulatory limit).
    public let maxTxPower: UInt8
}

// MARK: - Regional Preset

/// Regional LoRa presets with regulatory parameters.
///
/// Provides frequency and power limits for common ISM bands worldwide.
@available(iOS 17.0, macOS 14.0, *)
public enum RegionalPreset: String, CaseIterable, Identifiable {
    case us915 = "US 915 MHz"
    case eu868 = "EU 868 MHz"
    case au915 = "AU 915 MHz"
    case cn470 = "CN 470 MHz"

    public var id: String { rawValue }

    /// Get the regional parameters for this preset.
    public var parameters: RegionalParameters {
        switch self {
        case .us915:
            return RegionalParameters(
                frequency: 915_000_000,
                minFreq: 902_000_000,
                maxFreq: 928_000_000,
                maxTxPower: 30
            )
        case .eu868:
            return RegionalParameters(
                frequency: 868_000_000,
                minFreq: 863_000_000,
                maxFreq: 870_000_000,
                maxTxPower: 14
            )
        case .au915:
            return RegionalParameters(
                frequency: 915_000_000,
                minFreq: 915_000_000,
                maxFreq: 928_000_000,
                maxTxPower: 30
            )
        case .cn470:
            return RegionalParameters(
                frequency: 470_000_000,
                minFreq: 470_000_000,
                maxFreq: 510_000_000,
                maxTxPower: 19
            )
        }
    }
}

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

    /// Get the modem parameters for this preset.
    public var parameters: ModemParameters {
        switch self {
        case .shortTurbo:
            return ModemParameters(
                bandwidth: 500_000,
                spreadingFactor: 7,
                codingRate: 5
            )
        case .shortFast:
            return ModemParameters(
                bandwidth: 250_000,
                spreadingFactor: 7,
                codingRate: 5
            )
        case .shortSlow:
            return ModemParameters(
                bandwidth: 250_000,
                spreadingFactor: 8,
                codingRate: 5
            )
        case .mediumFast:
            return ModemParameters(
                bandwidth: 250_000,
                spreadingFactor: 9,
                codingRate: 5
            )
        case .mediumSlow:
            return ModemParameters(
                bandwidth: 250_000,
                spreadingFactor: 10,
                codingRate: 5
            )
        case .longFast:
            return ModemParameters(
                bandwidth: 250_000,
                spreadingFactor: 11,
                codingRate: 5
            )
        case .longModerate:
            return ModemParameters(
                bandwidth: 125_000,
                spreadingFactor: 11,
                codingRate: 8
            )
        case .longSlow:
            return ModemParameters(
                bandwidth: 125_000,
                spreadingFactor: 12,
                codingRate: 8
            )
        }
    }
}
