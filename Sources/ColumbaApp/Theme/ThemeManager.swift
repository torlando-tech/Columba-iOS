//
//  ThemeManager.swift
//  ColumbaApp
//
//  Observable singleton managing active theme state, color scheme preference,
//  and custom theme CRUD. Persists selections to UserDefaults.
//

import SwiftUI
import RNSAPI
import Observation

/// Central theme state manager.
///
/// All `Theme.*` computed properties delegate here. Views observe changes
/// through ThemeManager being `@Observable`, and the root view reads
/// `resolvedColorScheme` to trigger full-tree re-renders on theme change.
@available(iOS 17.0, macOS 14.0, *)
@Observable @MainActor
final class ThemeManager {
    // MARK: - Singleton

    static let shared = ThemeManager()

    // MARK: - State

    /// User's color scheme preference.
    var colorSchemePreference: ColorSchemePreference = .dark {
        didSet { persist() }
    }

    /// Currently active preset (nil if using custom theme).
    var activePresetId: PresetThemeId? = .plum {
        didSet { persist() }
    }

    /// Currently active custom theme ID (nil if using preset).
    var activeCustomThemeId: UUID? = nil {
        didSet { persist() }
    }

    /// All user-created custom themes.
    var customThemes: [CustomThemeData] = [] {
        didSet { persistCustomThemes() }
    }

    /// Bumped on every theme change to force root view re-render via `.id()`.
    var themeVersion: Int = 0

    // MARK: - Resolved Colors

    /// The active color palette (from preset or custom theme).
    var activeColors: ThemeColors {
        if let customId = activeCustomThemeId,
           let custom = customThemes.first(where: { $0.id == customId }) {
            return custom.generateColors()
        }
        return (activePresetId ?? .plum).colors
    }

    // MARK: - Color Scheme

    /// Resolved SwiftUI ColorScheme (nil = system).
    var resolvedColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The system's actual color scheme, updated from root view.
    var systemColorScheme: ColorScheme = .dark

    /// Whether the effective mode is dark.
    var isDarkMode: Bool {
        switch colorSchemePreference {
        case .dark: return true
        case .light: return false
        case .system: return systemColorScheme == .dark
        }
    }

    // MARK: - Color Accessors

    var accentColor: Color { Color(hex: activeColors.accentHex) }
    var secondaryAccent: Color { Color(hex: activeColors.secondaryAccentHex) }

    var backgroundPrimary: Color {
        isDarkMode ? Color(hex: activeColors.backgroundPrimaryHex)
                   : Color(hex: activeColors.lightBackgroundPrimaryHex)
    }
    var backgroundSecondary: Color {
        isDarkMode ? Color(hex: activeColors.backgroundSecondaryHex)
                   : Color(hex: activeColors.lightBackgroundSecondaryHex)
    }
    var backgroundTertiary: Color {
        isDarkMode ? Color(hex: activeColors.backgroundTertiaryHex)
                   : Color(hex: activeColors.lightBackgroundTertiaryHex)
    }

    var sentBubbleColor: Color { Color(hex: activeColors.sentBubbleHex) }
    var receivedBubbleColor: Color {
        isDarkMode ? Color(hex: activeColors.receivedBubbleHex)
                   : Color(hex: activeColors.lightReceivedBubbleHex)
    }

    var textPrimary: Color {
        isDarkMode ? Color.white.opacity(0.87) : Color.black.opacity(0.87)
    }
    var textSecondary: Color {
        isDarkMode ? Color.white.opacity(0.60) : Color.black.opacity(0.55)
    }
    var textDisabled: Color {
        isDarkMode ? Color.white.opacity(0.38) : Color.black.opacity(0.35)
    }
    var divider: Color {
        isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    var success: Color { Color(hex: activeColors.successHex) }
    var warning: Color { Color(hex: activeColors.warningHex) }
    var error: Color { Color(hex: activeColors.errorHex) }

    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, secondaryAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundPrimary, backgroundSecondary],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Init

    private init() {
        restore()
    }

    // MARK: - Selection Methods

    /// Select a preset theme.
    func selectPreset(_ preset: PresetThemeId) {
        activePresetId = preset
        activeCustomThemeId = nil
        themeVersion += 1
    }

    /// Select a custom theme by ID.
    func selectCustomTheme(_ id: UUID) {
        activeCustomThemeId = id
        activePresetId = nil
        themeVersion += 1
    }

    /// Set color scheme preference.
    func setColorScheme(_ pref: ColorSchemePreference) {
        colorSchemePreference = pref
        themeVersion += 1
    }

    // MARK: - Custom Theme CRUD

    /// Add a new custom theme and select it.
    func addCustomTheme(_ theme: CustomThemeData) {
        customThemes.append(theme)
        selectCustomTheme(theme.id)
    }

    /// Update an existing custom theme.
    func updateCustomTheme(_ theme: CustomThemeData) {
        if let index = customThemes.firstIndex(where: { $0.id == theme.id }) {
            customThemes[index] = theme
            if activeCustomThemeId == theme.id {
                themeVersion += 1
            }
        }
    }

    /// Delete a custom theme. If it was active, fall back to plum preset.
    func deleteCustomTheme(_ id: UUID) {
        customThemes.removeAll { $0.id == id }
        if activeCustomThemeId == id {
            activeCustomThemeId = nil
            activePresetId = .plum
            themeVersion += 1
        }
    }

    // MARK: - Persistence

    private static let colorSchemeKey = "theme_colorScheme"
    private static let presetIdKey = "theme_presetId"
    private static let customThemeIdKey = "theme_customThemeId"
    private static let customThemesKey = "theme_customThemes"

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(colorSchemePreference.rawValue, forKey: Self.colorSchemeKey)
        defaults.set(activePresetId?.rawValue, forKey: Self.presetIdKey)
        defaults.set(activeCustomThemeId?.uuidString, forKey: Self.customThemeIdKey)
    }

    private func persistCustomThemes() {
        if let data = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(data, forKey: Self.customThemesKey)
        }
    }

    private func restore() {
        let defaults = UserDefaults.standard

        if let raw = defaults.string(forKey: Self.colorSchemeKey),
           let pref = ColorSchemePreference(rawValue: raw) {
            colorSchemePreference = pref
        }

        if let raw = defaults.string(forKey: Self.presetIdKey),
           let preset = PresetThemeId(rawValue: raw) {
            activePresetId = preset
        }

        if let raw = defaults.string(forKey: Self.customThemeIdKey) {
            activeCustomThemeId = UUID(uuidString: raw)
            if activeCustomThemeId != nil {
                activePresetId = nil
            }
        }

        if let data = defaults.data(forKey: Self.customThemesKey),
           let themes = try? JSONDecoder().decode([CustomThemeData].self, from: data) {
            customThemes = themes
        }
    }
}
