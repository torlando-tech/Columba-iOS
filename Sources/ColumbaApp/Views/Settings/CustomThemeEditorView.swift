//
//  CustomThemeEditorView.swift
//  ColumbaApp
//
//  Sheet for creating or editing a custom theme with HSL sliders,
//  harmonized toggle, and live color preview.
//

import SwiftUI

// MARK: - Color Preset

@available(iOS 17.0, macOS 14.0, *)
private struct ColorPreset: Identifiable {
    let id = UUID()
    let name: String
    let hue: Double
    let saturation: Double
    let brightness: Double

    var color: Color {
        Color(hue: hue / 360, saturation: saturation, brightness: brightness)
    }

    static let all: [ColorPreset] = [
        ColorPreset(name: "Red",    hue: 0,   saturation: 0.75, brightness: 0.60),
        ColorPreset(name: "Orange", hue: 30,  saturation: 0.80, brightness: 0.65),
        ColorPreset(name: "Yellow", hue: 55,  saturation: 0.75, brightness: 0.65),
        ColorPreset(name: "Green",  hue: 130, saturation: 0.70, brightness: 0.55),
        ColorPreset(name: "Teal",   hue: 175, saturation: 0.70, brightness: 0.55),
        ColorPreset(name: "Blue",   hue: 215, saturation: 0.75, brightness: 0.60),
        ColorPreset(name: "Indigo", hue: 260, saturation: 0.70, brightness: 0.55),
        ColorPreset(name: "Violet", hue: 280, saturation: 0.70, brightness: 0.60),
        ColorPreset(name: "Pink",   hue: 330, saturation: 0.75, brightness: 0.60),
    ]
}

// MARK: - Gradient Slider

@available(iOS 17.0, macOS 14.0, *)
private struct GradientSliderView: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gradient: LinearGradient
    let trackHeight: CGFloat = 28
    let thumbSize: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = fraction * w

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(gradient)
                    .frame(height: trackHeight)

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = max(0, min(1, drag.location.x / w))
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: trackHeight)
    }
}

// MARK: - Hex Helpers

private func hsbToHex(hue: Double, saturation: Double, brightness: Double) -> String {
    let h = hue / 360
    let s = saturation
    let v = brightness

    let i = Int(h * 6) % 6
    let f = h * 6 - Double(Int(h * 6))
    let p = v * (1 - s)
    let q = v * (1 - f * s)
    let t = v * (1 - (1 - f) * s)

    let r, g, b: Double
    switch i {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }

    let ri = Int(round(r * 255))
    let gi = Int(round(g * 255))
    let bi = Int(round(b * 255))
    return String(format: "#%02X%02X%02X", ri, gi, bi)
}

private func hexToHSB(_ hex: String) -> (hue: Double, saturation: Double, brightness: Double)? {
    var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("#") { cleaned.removeFirst() }
    guard cleaned.count == 6 else { return nil }
    guard let val = UInt64(cleaned, radix: 16) else { return nil }

    let r = Double((val >> 16) & 0xFF) / 255.0
    let g = Double((val >> 8) & 0xFF) / 255.0
    let b = Double(val & 0xFF) / 255.0

    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let delta = maxC - minC

    let v = maxC
    let s = maxC == 0 ? 0 : delta / maxC

    var h: Double = 0
    if delta > 0 {
        if maxC == r {
            h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxC == g {
            h = 60 * (((b - r) / delta) + 2)
        } else {
            h = 60 * (((r - g) / delta) + 4)
        }
    }
    if h < 0 { h += 360 }

    return (hue: h, saturation: s, brightness: v)
}

// MARK: - Custom Theme Editor

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
    @State private var hexInput: String = ""
    @FocusState private var hexFieldFocused: Bool

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
                    nameField
                    previewSection
                    quickColorsSection
                    slidersSection
                    hexField
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
            hexInput = hsbToHex(hue: hue, saturation: saturation, brightness: brightness)
        }
        .onChange(of: hue) { syncHexFromSliders() }
        .onChange(of: saturation) { syncHexFromSliders() }
        .onChange(of: brightness) { syncHexFromSliders() }
    }

    private func syncHexFromSliders() {
        guard !hexFieldFocused else { return }
        hexInput = hsbToHex(hue: hue, saturation: saturation, brightness: brightness)
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

                HStack(alignment: .bottom, spacing: 8) {
                    Text("Hello!")
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Spacer()

                    Text("Hey there!")
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(previewAccent.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

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

    // MARK: - Quick Colors Section

    private var quickColorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK COLORS")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ColorPreset.all) { preset in
                        presetCircle(preset)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func presetCircle(_ preset: ColorPreset) -> some View {
        let isSelected = abs(hue - preset.hue) < 2
            && abs(saturation - preset.saturation) < 0.05
            && abs(brightness - preset.brightness) < 0.05

        return Button {
            hue = preset.hue
            saturation = preset.saturation
            brightness = preset.brightness
            hexInput = hsbToHex(hue: hue, saturation: saturation, brightness: brightness)
        } label: {
            ZStack {
                Circle()
                    .fill(preset.color)
                    .frame(width: 36, height: 36)

                if isSelected {
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: 36, height: 36)

                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
    }

    // MARK: - Sliders Section

    private var hueGradient: LinearGradient {
        LinearGradient(
            colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6.0).map { fraction in
                Color(hue: fraction, saturation: 0.8, brightness: 0.8)
            },
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var saturationGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue / 360, saturation: 0, brightness: brightness),
                Color(hue: hue / 360, saturation: 1, brightness: brightness)
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var brightnessGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue / 360, saturation: saturation, brightness: 0.1),
                Color(hue: hue / 360, saturation: saturation, brightness: 1.0)
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private var slidersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("COLOR CONTROLS")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)

            // Hue
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
                GradientSliderView(value: $hue, range: 0...360, gradient: hueGradient)
            }

            // Saturation
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
                GradientSliderView(value: $saturation, range: 0...1, gradient: saturationGradient)
            }

            // Brightness
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
                GradientSliderView(value: $brightness, range: 0.1...1, gradient: brightnessGradient)
            }
        }
    }

    // MARK: - Hex Field

    private var hexField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HEX COLOR")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                Circle()
                    .fill(previewAccent)
                    .frame(width: 28, height: 28)

                TextField("#RRGGBB", text: $hexInput)
                    .font(.body.monospaced())
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($hexFieldFocused)
                    .onChange(of: hexInput) {
                        guard hexFieldFocused else { return }
                        if let hsb = hexToHSB(hexInput) {
                            hue = hsb.hue
                            saturation = hsb.saturation
                            brightness = hsb.brightness
                        }
                    }
                    .onSubmit {
                        hexInput = hsbToHex(hue: hue, saturation: saturation, brightness: brightness)
                    }
            }
            .padding(12)
            .background(Theme.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
