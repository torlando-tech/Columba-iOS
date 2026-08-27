//
//  ThemeManager.swift
//  ColumbaApp
//
//  Observable singleton managing active theme state, color scheme preference,
//  and custom theme CRUD. Persists selections to UserDefaults.
//

import Foundation
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

    @ObservationIgnored
    private let defaults: UserDefaults

    // MARK: - State
    //
    // Persistence-sensitive state. These are `private(set)` so the only
    // writers are the mutation methods below (each of which persists the
    // aggregate state) and `restore()`. A direct write from any other module
    // location would change live theme state without updating `theme_state`,
    // silently losing that change on relaunch.

    /// User's color scheme preference.
    private(set) var colorSchemePreference: ColorSchemePreference = .dark

    /// Currently active preset (nil if using custom theme).
    private(set) var activePresetId: PresetThemeId? = .plum

    /// Currently active custom theme ID (nil if using preset).
    private(set) var activeCustomThemeId: UUID? = nil

    /// All user-created custom themes.
    private(set) var customThemes: [CustomThemeData] = []

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

    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    // MARK: - Selection Methods

    /// Select a preset theme.
    func selectPreset(_ preset: PresetThemeId) {
        activePresetId = preset
        activeCustomThemeId = nil
        persistState()
    }

    /// Select a custom theme by ID.
    func selectCustomTheme(_ id: UUID) {
        guard customThemes.contains(where: { $0.id == id }) else {
            activeCustomThemeId = nil
            activePresetId = .plum
            persistState()
            return
        }

        activeCustomThemeId = id
        activePresetId = nil
        persistState()
    }

    /// Set color scheme preference.
    func setColorScheme(_ pref: ColorSchemePreference) {
        colorSchemePreference = pref
        persistState()
    }

    // MARK: - Custom Theme CRUD

    /// Add a new custom theme and select it.
    func addCustomTheme(_ theme: CustomThemeData) {
        customThemes.append(theme)
        activeCustomThemeId = theme.id
        activePresetId = nil
        persistState()
    }

    /// Update an existing custom theme.
    func updateCustomTheme(_ theme: CustomThemeData) {
        if let index = customThemes.firstIndex(where: { $0.id == theme.id }) {
            customThemes[index] = theme
            persistState()
        }
    }

    /// Delete a custom theme. If it was active, fall back to plum preset.
    func deleteCustomTheme(_ id: UUID) {
        let countBeforeDeletion = customThemes.count
        customThemes.removeAll { $0.id == id }
        let removedTheme = customThemes.count != countBeforeDeletion
        let wasActive = activeCustomThemeId == id
        if wasActive {
            activeCustomThemeId = nil
            activePresetId = .plum
        }
        if removedTheme || wasActive {
            persistState()
        }
    }

    // MARK: - Persistence

    private static let stateKey = "theme_state"
    private static let colorSchemeKey = "theme_colorScheme"
    private static let presetIdKey = "theme_presetId"
    private static let customThemeIdKey = "theme_customThemeId"
    private static let customThemesKey = "theme_customThemes"

    private struct PersistedThemeState: Codable {
        let colorSchemeRawValue: String
        let presetRawValue: String?
        let customThemeID: UUID?
        let customThemes: [CustomThemeData]
    }

    private func persistState() {
        let state = PersistedThemeState(
            colorSchemeRawValue: colorSchemePreference.rawValue,
            presetRawValue: activePresetId?.rawValue,
            customThemeID: activeCustomThemeId,
            customThemes: customThemes
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    private func restore() {
        let state = defaults.data(forKey: Self.stateKey).flatMap {
            try? JSONDecoder().decode(PersistedThemeState.self, from: $0)
        }

        let restoredColorScheme = ColorSchemePreference(
            rawValue: state?.colorSchemeRawValue
                ?? defaults.string(forKey: Self.colorSchemeKey)
                ?? ""
        ) ?? .dark
        let restoredCustomThemes = state?.customThemes ?? {
            guard let data = defaults.data(forKey: Self.customThemesKey),
                  let themes = try? JSONDecoder().decode([CustomThemeData].self, from: data) else {
                return []
            }
            return themes
        }()
        let restoredPresetRawValue: String?
        let restoredCustomThemeId: UUID?
        if let state {
            restoredPresetRawValue = state.presetRawValue
            restoredCustomThemeId = state.customThemeID
        } else {
            restoredPresetRawValue = defaults.string(forKey: Self.presetIdKey)
            restoredCustomThemeId = defaults.string(forKey: Self.customThemeIdKey)
                .flatMap(UUID.init(uuidString:))
        }
        let restoredPresetId = restoredPresetRawValue.flatMap(PresetThemeId.init(rawValue:))

        colorSchemePreference = restoredColorScheme
        customThemes = restoredCustomThemes

        if let customThemeId = restoredCustomThemeId,
           restoredCustomThemes.contains(where: { $0.id == customThemeId }) {
            activeCustomThemeId = customThemeId
            activePresetId = nil
        } else {
            activeCustomThemeId = nil
            activePresetId = restoredPresetId ?? .plum
        }
    }
}
