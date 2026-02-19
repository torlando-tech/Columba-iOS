//
//  ThemeColors.swift
//  ColumbaApp
//
//  Data models for theme customization: color palettes, presets, and custom themes.
//

import SwiftUI

// MARK: - Theme Colors

/// Complete color palette for a theme.
struct ThemeColors: Codable, Equatable {
    var accentHex: String
    var secondaryAccentHex: String
    var backgroundPrimaryHex: String
    var backgroundSecondaryHex: String
    var backgroundTertiaryHex: String
    var lightBackgroundPrimaryHex: String
    var lightBackgroundSecondaryHex: String
    var lightBackgroundTertiaryHex: String
    var sentBubbleHex: String
    var receivedBubbleHex: String
    var lightReceivedBubbleHex: String
    var successHex: String
    var warningHex: String
    var errorHex: String
}

// MARK: - Preset Theme ID

/// Built-in theme presets matching Android Columba.
enum PresetThemeId: String, Codable, CaseIterable, Identifiable {
    case plum, teal, ocean, sunset, forest, rose, midnight, lavender

    var id: String { rawValue }

    var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    var colors: ThemeColors {
        switch self {
        case .plum:
            return ThemeColors(
                accentHex: "#9C27B0", secondaryAccentHex: "#E040FB",
                backgroundPrimaryHex: "#111114", backgroundSecondaryHex: "#1C1C1E",
                backgroundTertiaryHex: "#28282C",
                lightBackgroundPrimaryHex: "#F5F0F7", lightBackgroundSecondaryHex: "#EDE5F0",
                lightBackgroundTertiaryHex: "#E0D5E5",
                sentBubbleHex: "#9C27B0", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#E8E0EC",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        case .teal:
            return ThemeColors(
                accentHex: "#009688", secondaryAccentHex: "#4DB6AC",
                backgroundPrimaryHex: "#101414", backgroundSecondaryHex: "#1A1F1F",
                backgroundTertiaryHex: "#252C2C",
                lightBackgroundPrimaryHex: "#F0F5F5", lightBackgroundSecondaryHex: "#E0EDED",
                lightBackgroundTertiaryHex: "#D0E0E0",
                sentBubbleHex: "#009688", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#E0ECEB",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        case .ocean:
            return ThemeColors(
                accentHex: "#1565C0", secondaryAccentHex: "#42A5F5",
                backgroundPrimaryHex: "#101218", backgroundSecondaryHex: "#1A1D24",
                backgroundTertiaryHex: "#252830",
                lightBackgroundPrimaryHex: "#F0F3F8", lightBackgroundSecondaryHex: "#E0E8F0",
                lightBackgroundTertiaryHex: "#D0DCE8",
                sentBubbleHex: "#1565C0", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#E0E8F0",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        case .sunset:
            return ThemeColors(
                accentHex: "#E65100", secondaryAccentHex: "#FF8A65",
                backgroundPrimaryHex: "#141210", backgroundSecondaryHex: "#1F1C1A",
                backgroundTertiaryHex: "#2C2825",
                lightBackgroundPrimaryHex: "#F8F3F0", lightBackgroundSecondaryHex: "#F0E5E0",
                lightBackgroundTertiaryHex: "#E8D8D0",
                sentBubbleHex: "#E65100", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#F0E5E0",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        case .forest:
            return ThemeColors(
                accentHex: "#2E7D32", secondaryAccentHex: "#66BB6A",
                backgroundPrimaryHex: "#101410", backgroundSecondaryHex: "#1A1F1A",
                backgroundTertiaryHex: "#252C25",
                lightBackgroundPrimaryHex: "#F0F5F0", lightBackgroundSecondaryHex: "#E0EDE0",
                lightBackgroundTertiaryHex: "#D0E0D0",
                sentBubbleHex: "#2E7D32", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#E0ECE0",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        case .rose:
            return ThemeColors(
                accentHex: "#AD1457", secondaryAccentHex: "#F06292",
                backgroundPrimaryHex: "#141012", backgroundSecondaryHex: "#1F1A1C",
                backgroundTertiaryHex: "#2C2528",
                lightBackgroundPrimaryHex: "#F8F0F3", lightBackgroundSecondaryHex: "#F0E0E5",
                lightBackgroundTertiaryHex: "#E8D0D8",
                sentBubbleHex: "#AD1457", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#F0E0E8",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        case .midnight:
            return ThemeColors(
                accentHex: "#283593", secondaryAccentHex: "#7986CB",
                backgroundPrimaryHex: "#101014", backgroundSecondaryHex: "#1A1A20",
                backgroundTertiaryHex: "#25252C",
                lightBackgroundPrimaryHex: "#F0F0F5", lightBackgroundSecondaryHex: "#E0E0ED",
                lightBackgroundTertiaryHex: "#D0D0E0",
                sentBubbleHex: "#283593", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#E0E0EC",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        case .lavender:
            return ThemeColors(
                accentHex: "#7B1FA2", secondaryAccentHex: "#CE93D8",
                backgroundPrimaryHex: "#121014", backgroundSecondaryHex: "#1D1A20",
                backgroundTertiaryHex: "#28252C",
                lightBackgroundPrimaryHex: "#F5F0F8", lightBackgroundSecondaryHex: "#EDE0F0",
                lightBackgroundTertiaryHex: "#E0D0E8",
                sentBubbleHex: "#7B1FA2", receivedBubbleHex: "#262626",
                lightReceivedBubbleHex: "#EDE0F0",
                successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
            )
        }
    }
}

// MARK: - Color Scheme Preference

/// User's preferred color scheme setting.
enum ColorSchemePreference: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "gear"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Custom Theme Data

/// User-created custom theme with HSL parameters.
struct CustomThemeData: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var primaryHue: Double       // 0...360
    var saturation: Double       // 0...1
    var brightness: Double       // 0...1
    var harmonized: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String = "Custom Theme", primaryHue: Double = 280,
         saturation: Double = 0.7, brightness: Double = 0.5, harmonized: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.primaryHue = primaryHue
        self.saturation = saturation
        self.brightness = brightness
        self.harmonized = harmonized
        self.createdAt = createdAt
    }

    /// Generate a full color palette from HSL parameters.
    func generateColors() -> ThemeColors {
        let accent = Color(hue: primaryHue / 360, saturation: saturation, brightness: brightness)
        let accentHex = accent.toHex()

        // Secondary: harmonized uses 60-degree hue rotation, otherwise lighter version
        let secondaryHue = harmonized ? (primaryHue + 60).truncatingRemainder(dividingBy: 360) : primaryHue
        let secondarySat = harmonized ? saturation * 0.8 : saturation * 0.6
        let secondaryBri = min(brightness + 0.25, 1.0)
        let secondary = Color(hue: secondaryHue / 360, saturation: secondarySat, brightness: secondaryBri)
        let secondaryHex = secondary.toHex()

        // Dark backgrounds tinted with accent hue
        let bgHue = primaryHue / 360
        let bgPrimary = Color(hue: bgHue, saturation: 0.08, brightness: 0.07)
        let bgSecondary = Color(hue: bgHue, saturation: 0.06, brightness: 0.11)
        let bgTertiary = Color(hue: bgHue, saturation: 0.05, brightness: 0.16)

        // Light backgrounds
        let lightBgPrimary = Color(hue: bgHue, saturation: 0.06, brightness: 0.96)
        let lightBgSecondary = Color(hue: bgHue, saturation: 0.08, brightness: 0.92)
        let lightBgTertiary = Color(hue: bgHue, saturation: 0.10, brightness: 0.88)

        return ThemeColors(
            accentHex: accentHex, secondaryAccentHex: secondaryHex,
            backgroundPrimaryHex: bgPrimary.toHex(),
            backgroundSecondaryHex: bgSecondary.toHex(),
            backgroundTertiaryHex: bgTertiary.toHex(),
            lightBackgroundPrimaryHex: lightBgPrimary.toHex(),
            lightBackgroundSecondaryHex: lightBgSecondary.toHex(),
            lightBackgroundTertiaryHex: lightBgTertiary.toHex(),
            sentBubbleHex: accentHex,
            receivedBubbleHex: "#262626",
            lightReceivedBubbleHex: lightBgSecondary.toHex(),
            successHex: "#4CAF50", warningHex: "#FFC107", errorHex: "#F44336"
        )
    }
}

// MARK: - Color Hex Extension

extension Color {
    /// Convert Color to hex string.
    func toHex() -> String {
        #if canImport(UIKit)
        guard let components = UIColor(self).cgColor.components else { return "#000000" }
        #elseif canImport(AppKit)
        guard let components = NSColor(self).cgColor.components else { return "#000000" }
        #else
        return "#000000"
        #endif
        let r = Int(min(max(components[0], 0), 1) * 255)
        let g = Int(min(max(components.count > 1 ? components[1] : 0, 0), 1) * 255)
        let b = Int(min(max(components.count > 2 ? components[2] : 0, 0), 1) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
