//
//  VoiceQualityPickerSheet.swift
//  ColumbaApp
//
//  Quality picker for a new voice message. Ports Android Columba's
//  `QualitySelectionDialog` (invoked from `MessagingScreen` with the voice
//  options). Mirrors the iOS `ImageQualityPickerSheet` layout: a scrollable
//  list of radio rows with the header and the Record / Cancel buttons pinned,
//  a "Recommended" star chip on the default profile, and a confirm button that
//  starts recording.
//
//  The exact strings live in `Localizable.xcstrings` (see Section 3 of the
//  voice-messages parity plan); the static contract test asserts the literal
//  values so a wording drift fails CI.
//

import SwiftUI
import RNSAPI

/// A bottom sheet for selecting a voice-message quality profile, then starting
/// recording. `onConfirm` is called with the chosen profile when the user taps
/// Record; `onCancel` when they dismiss.
@available(iOS 17.0, macOS 14.0, *)
public struct VoiceQualityPickerSheet: View {
    var sheetHeight: CGFloat
    @Binding var selectedFormat: VoiceMessageFormat
    var onConfirm: (VoiceMessageFormat) -> Void
    var onCancel: () -> Void

    private let recommended = VoiceMessageFormat.defaultFormat

    public init(
        sheetHeight: CGFloat,
        selectedFormat: Binding<VoiceMessageFormat>,
        onConfirm: @escaping (VoiceMessageFormat) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.sheetHeight = sheetHeight
        self._selectedFormat = selectedFormat
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Select Voice Message Quality"))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("voice_quality_title")
                Text(String(localized: "Choose the recording format and bandwidth"))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("voice_quality_subtitle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            // The quality options scroll independently while the header and the
            // Record / Cancel buttons stay pinned (same pattern as the image
            // quality sheet, issue #181).
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(VoiceMessageFormat.outboundOptions) { format in
                        optionRow(format)
                    }
                }
            }
            .accessibilityIdentifier("voice_quality_options")

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(String(localized: "Cancel"))
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.backgroundTertiary)
                        .clipShape(Capsule())
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(VoicePickerScaleButtonStyle())
                .accessibilityIdentifier("voice_quality_cancel_button")

                Button {
                    onConfirm(selectedFormat)
                } label: {
                    Text(String(localized: "Record"))
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accentColor)
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(VoicePickerScaleButtonStyle())
                .accessibilityIdentifier("voice_quality_record_button")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .frame(height: sheetHeight)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func optionRow(_ format: VoiceMessageFormat) -> some View {
        let isSelected = format == selectedFormat
        let isRecommended = format.isRecommended
        return Button {
            selectedFormat = format
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.accentColor : .gray)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(format.displayName)
                            .font(.subheadline.weight(isRecommended ? .semibold : .medium))
                            .foregroundStyle(Theme.textPrimary)
                        if isRecommended {
                            // Star chip = the "Recommended" badge (a11y label
                            // mirrors Android's `RecommendedChip`).
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accentColor)
                                .accessibilityLabel("Recommended")
                                .accessibilityIdentifier("voice_quality_recommended_badge")
                        }
                    }
                    Text(format.description)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected
                    ? Theme.accentColor.opacity(0.15)
                    : Theme.backgroundTertiary
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Theme.accentColor : Theme.divider, lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(VoicePickerScaleButtonStyle())
        .accessibilityIdentifier("voice_quality_option_\(format.id)")
        .accessibilityLabel(Text(format.displayName))
        .accessibilityHint(Text(format.description))
    }
}

/// Button style that scales down slightly on press (matches the composer's).
private struct VoicePickerScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
