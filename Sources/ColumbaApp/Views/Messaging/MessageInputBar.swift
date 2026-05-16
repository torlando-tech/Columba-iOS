//
//  MessageInputBar.swift
//  Columba-iOS
//
//  Input component with text field, image picker, attachment, and send buttons.
//  Uses glass material background matching Android Columba design.
//

import SwiftUI
import RNSAPI
#if canImport(UIKit)
import UIKit
#endif

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
    @Binding var attachedImage: UIImage?
    @Binding var attachedFiles: [FileAttachment]
    var replyToMessage: Message?
    var onDismissReply: (() -> Void)?
    var onSend: () -> Void
    var onImagePicker: () -> Void
    var onAttachment: () -> Void

    @FocusState private var isFocused: Bool

    // MARK: - Theme (delegates to Theme/ThemeManager)

    // MARK: - Computed Properties

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || attachedImage != nil
        || !attachedFiles.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Top separator
            Divider()
                .background(Theme.divider)

            // Reply-to preview bar
            if let replyMsg = replyToMessage {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accentColor)
                        .frame(width: 3, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replying to")
                            .font(.caption2)
                            .foregroundStyle(Theme.accentColor)
                        Text(replyMsg.content.isEmpty ? "Message" : String(replyMsg.content.prefix(60)))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        onDismissReply?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }

            // Attachment preview strip
            if attachedImage != nil || !attachedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Image preview
                        if let image = attachedImage {
                            ZStack(alignment: .topTrailing) {
                                Image(platformImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                Button {
                                    withAnimation { attachedImage = nil }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 6, y: -6)
                            }
                        }

                        // File chips
                        ForEach(Array(attachedFiles.indices), id: \.self) { index in
                            fileChipView(index: index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                // Text field container
                HStack(alignment: .bottom, spacing: 8) {
                    // Text field
                    TextField("Type a message...", text: $text, axis: .vertical)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1...6)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 0.5)
                )

                // Action buttons
                HStack(spacing: 12) {
                    // Image picker button
                    Button(action: onImagePicker) {
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(ScaleButtonStyle())

                    // Attachment button
                    Button(action: onAttachment) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.textSecondary)
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
                            .foregroundStyle(canSend ? Theme.accentColor : Color.gray.opacity(0.5))
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

    // MARK: - File Chip View

    private func fileChipView(index: Int) -> some View {
        let fileName = attachedFiles[index].name
        return HStack(spacing: 4) {
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundColor(Theme.textSecondary)
            Text(fileName)
                .font(.caption)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Button {
                withAnimation { _ = attachedFiles.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.backgroundTertiary)
        .clipShape(Capsule())
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
            attachedImage: .constant(nil as UIImage?),
            attachedFiles: .constant([]),
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
            attachedImage: .constant(nil as UIImage?),
            attachedFiles: .constant([]),
            onSend: {},
            onImagePicker: {},
            onAttachment: {}
        )
    }
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("With Reply") {
    VStack {
        Spacer()
        MessageInputBar(
            text: .constant(""),
            attachedImage: .constant(nil as UIImage?),
            attachedFiles: .constant([]),
            replyToMessage: Message(content: "Hey, did you see the news?", isFromMe: false),
            onDismissReply: {},
            onSend: {},
            onImagePicker: {},
            onAttachment: {}
        )
    }
    .background(Color.black)
    .preferredColorScheme(.dark)
}
