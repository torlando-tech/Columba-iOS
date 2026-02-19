//
//  CustomThemeEditorView.swift
//  ColumbaApp
//
//  Sheet for creating or editing a custom theme with HSL sliders,
//  harmonized toggle, and live color preview.
//

import SwiftUI

/// Custom theme editor with HSL sliders and live preview.
@available(iOS 17.0, macOS 14.0, *)
struct CustomThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// Pass an existing theme to edit, or nil to create new.
    let existingTheme: CustomThemeData?

    @State private var name: String = "Custom Theme"
    @State private var hue: Double = 280
    @State private var saturation: Double = 0.7
    @State private var brightness: Double = 0.5
    @State private var harmonized: Bool = true

    private var themeManager: ThemeManager { ThemeManager.shared }

    private var previewAccent: Color {
        Color(hue: hue / 360, saturation: saturation, brightness: brightness)
    }

    private var previewSecondary: Color {
        let secHue = harmonized ? (hue + 60).truncatingRemainder(dividingBy: 360) : hue
        let secSat = harmonized ? saturation * 0.8 : saturation * 0.6
        let secBri = min(brightness + 0.25, 1.0)
        return Color(hue: secHue / 360, saturation: secSat, brightness: secBri)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name field
                    nameField

                    // Live Preview
                    previewSection

                    // HSL Sliders
                    slidersSection

                    // Harmonized toggle
                    harmonizedToggle
                }
                .padding(16)
            }
            .background(Theme.backgroundPrimary)
            .navigationTitle(existingTheme != nil ? "Edit Theme" : "New Theme")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            #endif
        }
        .onAppear {
            if let theme = existingTheme {
                name = theme.name
                hue = theme.primaryHue
                saturation = theme.saturation
                brightness = theme.brightness
                harmonized = theme.harmonized
            }
        }
    }

    // MARK: - Name Field

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THEME NAME")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)

            TextField("Theme name", text: $name)
                .font(.body)
                .foregroundStyle(.white)
                .padding(12)
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 12) {
                // Accent button preview
                HStack {
                    Text("Accent Button")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [previewAccent, previewSecondary],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Spacer()
                }

                // Bubble preview
                HStack(alignment: .bottom, spacing: 8) {
                    // Received bubble
                    Text("Hello!")
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Spacer()

                    // Sent bubble
                    Text("Hey there!")
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(previewAccent.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                // Color circles
                HStack(spacing: 12) {
                    colorDot("Accent", color: previewAccent)
                    colorDot("Secondary", color: previewSecondary)
                    Spacer()
                }
            }
            .padding(16)
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func colorDot(_ label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Sliders Section

    private var slidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("COLOR CONTROLS")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)

            // Hue slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Hue")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int(hue))\u{00B0}")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $hue, in: 0...360)
                    .tint(previewAccent)
            }

            // Saturation slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Saturation")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int(saturation * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $saturation, in: 0...1)
                    .tint(previewAccent)
            }

            // Brightness slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(Int(brightness * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Slider(value: $brightness, in: 0.1...1)
                    .tint(previewAccent)
            }
        }
    }

    // MARK: - Harmonized Toggle

    private var harmonizedToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Harmonized Colors")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Auto-generate secondary color via 60\u{00B0} hue rotation")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $harmonized)
                .toggleStyle(AccentToggleStyle())
                .labelsHidden()
        }
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "Custom Theme" : trimmedName

        if var existing = existingTheme {
            existing.name = finalName
            existing.primaryHue = hue
            existing.saturation = saturation
            existing.brightness = brightness
            existing.harmonized = harmonized
            themeManager.updateCustomTheme(existing)
        } else {
            let newTheme = CustomThemeData(
                name: finalName,
                primaryHue: hue,
                saturation: saturation,
                brightness: brightness,
                harmonized: harmonized
            )
            themeManager.addCustomTheme(newTheme)
        }

        dismiss()
    }
}
