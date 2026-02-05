//
//  MessageInputBar.swift
//  Columba-iOS
//
//  Input component with text field, image picker, attachment, and send buttons.
//  Uses glass material background matching Android Columba design.
//

import SwiftUI

/// Message input bar with text field and action buttons.
///
/// Features:
/// - Auto-expanding TextField (1-6 lines)
/// - Image picker button (photo)
/// - Attachment button (paperclip)
/// - Send button (arrow.up.circle.fill) with purple accent
/// - Glass material background
struct MessageInputBar: View {
    // MARK: - Properties

    @Binding var text: String
    var onSend: () -> Void
    var onImagePicker: () -> Void
    var onAttachment: () -> Void

    @FocusState private var isFocused: Bool

    /// Purple accent color matching Android Columba (Hex: #6750A4)
    private let accentColor = Color(red: 0.404, green: 0.314, blue: 0.643)

    /// Darker background for text field
    private let textFieldBackground = Color(white: 0.12)

    // MARK: - Computed Properties

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Top separator
            Divider()
                .background(Color.white.opacity(0.1))

            HStack(alignment: .bottom, spacing: 12) {
                // Text field container
                HStack(alignment: .bottom, spacing: 8) {
                    // Text field
                    TextField("Type a message...", text: $text, axis: .vertical)
                        .font(.body)
                        .foregroundStyle(.white)
                        .lineLimit(1...6)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .background(textFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )

                // Action buttons
                HStack(spacing: 12) {
                    // Image picker button
                    Button(action: onImagePicker) {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(ScaleButtonStyle())

                    // Attachment button
                    Button(action: onAttachment) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(ScaleButtonStyle())

                    // Send button
                    Button(action: {
                        if canSend {
                            onSend()
                        }
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(canSend ? accentColor : Color.gray.opacity(0.5))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Scale Button Style

/// Button style that scales down slightly on press.
private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        MessageInputBar(
            text: .constant(""),
            onSend: {},
            onImagePicker: {},
            onAttachment: {}
        )
    }
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("With Text") {
    VStack {
        Spacer()
        MessageInputBar(
            text: .constant("Hello, this is a test message"),
            onSend: {},
            onImagePicker: {},
            onAttachment: {}
        )
    }
    .background(Color.black)
    .preferredColorScheme(.dark)
}
