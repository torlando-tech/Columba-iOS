import SwiftUI

// MARK: - Text Size Picker Sheet

@available(iOS 17.0, macOS 14.0, *)
struct TextSizePickerSheet: View {
    let onSave: (Double) -> Void

    @State private var selectedScale: Double
    @ScaledMetric(relativeTo: .body) private var previewBodyFontSize: CGFloat = 17
    @Environment(\.dismiss) private var dismiss

    init(currentScale: Double, onSave: @escaping (Double) -> Void) {
        self.onSave = onSave
        _selectedScale = State(initialValue: SettingsRepository.MessageTextScale.normalize(currentScale))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Preview message text")
                        .font(.system(size: previewBodyFontSize * CGFloat(selectedScale)))
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .padding(14)
                        .background(Theme.receivedBubbleColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("text_size_preview")

                    Text("\(Int((selectedScale * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("text_size_percent")

                    Slider(
                        value: $selectedScale,
                        in: SettingsRepository.MessageTextScale.minimum...SettingsRepository.MessageTextScale.maximum,
                        step: SettingsRepository.MessageTextScale.step
                    )
                    .accessibilityIdentifier("text_size_slider")
                    .accessibilityLabel("Message text size")
                    .accessibilityValue(Text("\(Int((selectedScale * 100).rounded())) percent"))

                    HStack {
                        Text("A")
                            .font(.system(size: 17 * SettingsRepository.MessageTextScale.minimum))
                            .accessibilityLabel("Minimum text size")
                        Spacer()
                        Text("A")
                            .font(.system(size: 17 * SettingsRepository.MessageTextScale.maximum))
                            .accessibilityLabel("Maximum text size")
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("text_size_range_labels")
                }
                .padding()
            }
            .navigationTitle("Text Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("text_size_cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        onSave(selectedScale)
                        dismiss()
                    }
                    .accessibilityIdentifier("text_size_confirm")
                }
            }
        }
    }
}
