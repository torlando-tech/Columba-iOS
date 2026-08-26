//
//  AppearanceCard.swift
//  ColumbaApp
//
//  Expandable settings card for theme customization.
//  Color scheme picker, preset grid, and custom theme management.
//

import SwiftUI
import RNSAPI

/// Appearance settings card with color scheme, presets, and custom themes.
@available(iOS 17.0, macOS 14.0, *)
struct AppearanceCard: View {
    @Binding var isExpanded: Bool
    @State private var showCustomThemeEditor = false
    @State private var editingTheme: CustomThemeData?

    private var themeManager: ThemeManager { ThemeManager.shared }

    var body: some View {
        ExpandableSettingsCard(
            icon: "paintbrush.fill",
            title: "Appearance",
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 16) {
                // Color Scheme
                colorSchemePicker

                Divider()
                    .padding(.vertical, 4)

                // Preset Themes
                Text("THEME")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textSecondary)

                presetGrid

                // Custom Themes
                if !themeManager.customThemes.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    Text("CUSTOM THEMES")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.textSecondary)

                    customThemesList
                }

                // Create Custom Theme Button
                Button {
                    editingTheme = nil
                    showCustomThemeEditor = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                        Text("Create Custom Theme")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                }
            }
        }
        .sheet(isPresented: $showCustomThemeEditor) {
            CustomThemeEditorView(existingTheme: editingTheme)
        }
    }

    // MARK: - Color Scheme Picker

    private var colorSchemePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COLOR SCHEME")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                ForEach(ColorSchemePreference.allCases, id: \.self) { pref in
                    Button {
                        themeManager.setColorScheme(pref)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: pref.icon)
                                .font(.system(size: 12, weight: .medium))
                            Text(pref.displayName)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(
                            themeManager.colorSchemePreference == pref ? .white : Theme.textSecondary
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            themeManager.colorSchemePreference == pref
                                ? Theme.accentColor
                                : Theme.backgroundTertiary
                        )
                        .clipShape(Capsule())
                    }
                    .accessibilityIdentifier("appearance_color_scheme_\(pref.rawValue)")
                    .accessibilityAddTraits(
                        themeManager.colorSchemePreference == pref ? .isSelected : []
                    )
                }
            }
        }
    }

    // MARK: - Preset Grid

    private var presetGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()),
            GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 12) {
            ForEach(PresetThemeId.allCases) { preset in
                presetCircle(preset)
            }
        }
    }

    private func presetCircle(_ preset: PresetThemeId) -> some View {
        Button {
            themeManager.selectPreset(preset)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color(hex: preset.colors.accentHex))
                        .frame(width: 44, height: 44)

                    if themeManager.activePresetId == preset && themeManager.activeCustomThemeId == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    if themeManager.activePresetId == preset && themeManager.activeCustomThemeId == nil {
                        Circle()
                            .stroke(Color.white.opacity(0.4), lineWidth: 2)
                            .frame(width: 50, height: 50)
                    }
                }

                Text(preset.displayName)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("appearance_theme_\(preset.rawValue)")
            .accessibilityAddTraits(
                themeManager.activePresetId == preset && themeManager.activeCustomThemeId == nil
                    ? .isSelected
                    : []
            )
        }
    }

    // MARK: - Custom Themes List

    private var customThemesList: some View {
        VStack(spacing: 8) {
            ForEach(themeManager.customThemes) { theme in
                customThemeRow(theme)
            }
        }
    }

    private func customThemeRow(_ theme: CustomThemeData) -> some View {
        HStack(spacing: 12) {
            // Color preview
            Circle()
                .fill(Color(hue: theme.primaryHue / 360, saturation: theme.saturation, brightness: theme.brightness))
                .frame(width: 32, height: 32)
                .overlay {
                    if themeManager.activeCustomThemeId == theme.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

            Text(theme.name)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer()

            // Edit button
            Button {
                editingTheme = theme
                showCustomThemeEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }

            // Delete button
            Button {
                themeManager.deleteCustomTheme(theme.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            themeManager.activeCustomThemeId == theme.id
                ? Theme.accentColor.opacity(0.15)
                : Theme.backgroundTertiary
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            themeManager.selectCustomTheme(theme.id)
        }
    }
}
