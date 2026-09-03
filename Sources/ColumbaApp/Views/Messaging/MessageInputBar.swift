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

enum ComposerKeyboardPreference {
    static let key = "send_message_on_return"
    static let defaultValue = true

    static func sendsOnReturn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

enum ComposerReturnDecision {
    static func shouldSubmit(
        replacementText: String,
        sendsOnReturn: Bool,
        hasMarkedText: Bool,
        isPerformingPaste: Bool
    ) -> Bool {
        replacementText == "\n"
            && sendsOnReturn
            && !hasMarkedText
            && !isPerformingPaste
    }
}

#if os(iOS)
private final class ComposerUITextView: UITextView {
    private(set) var isPerformingPaste = false
    private var pasteGeneration = 0

    override func paste(_ sender: Any?) {
        pasteGeneration += 1
        let generation = pasteGeneration
        isPerformingPaste = true

        // UIKit 26.6 can discard a newline-only paste before mutating a
        // UITextView. Route that exact payload through UIKeyInput so it still
        // follows the native delegate path and replaces the current selection.
        if UIPasteboard.general.string == "\n" {
            insertText("\n")
            finishPasteIfNeeded(generation: generation)
            return
        }

        super.paste(sender)
        finishPasteIfNeeded(generation: generation)
    }

    private func finishPasteIfNeeded(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pasteGeneration == generation else { return }
            self.isPerformingPaste = false
        }
    }

    func finishPaste() {
        isPerformingPaste = false
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let sendsOnReturn: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, sendsOnReturn: sendsOnReturn, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = UIColor(Theme.textPrimary)
        textView.tintColor = UIColor(Theme.accentColor)
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.accessibilityIdentifier = "message_composer"
        textView.accessibilityLabel = String(localized: "Type a message...")
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.sendsOnReturn = sendsOnReturn
        context.coordinator.onSubmit = onSubmit
        textView.returnKeyType = sendsOnReturn ? .send : .default
        textView.textColor = UIColor(Theme.textPrimary)
        textView.tintColor = UIColor(Theme.accentColor)
        if textView.text != text {
            textView.text = text
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let verticalInsets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let minimumHeight = lineHeight + verticalInsets
        let maximumHeight = lineHeight * 6 + verticalInsets
        let height = min(max(fittingSize.height, minimumHeight), maximumHeight)
        uiView.isScrollEnabled = fittingSize.height > maximumHeight
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var sendsOnReturn: Bool
        var onSubmit: () -> Void

        init(text: Binding<String>, sendsOnReturn: Bool, onSubmit: @escaping () -> Void) {
            self.text = text
            self.sendsOnReturn = sendsOnReturn
            self.onSubmit = onSubmit
        }

        func textViewDidChange(_ textView: UITextView) {
            defer { (textView as? ComposerUITextView)?.finishPaste() }
            text.wrappedValue = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            let shouldSubmit = ComposerReturnDecision.shouldSubmit(
                replacementText: replacement,
                sendsOnReturn: sendsOnReturn,
                hasMarkedText: textView.markedTextRange != nil,
                isPerformingPaste: (textView as? ComposerUITextView)?.isPerformingPaste == true
            )
            guard shouldSubmit else { return true }
            onSubmit()
            return false
        }
    }
}
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
    /// Mic tap: opens the voice quality picker and, on confirm, starts
    /// recording. nil hides the button (callers that don't support voice).
    var onVoiceRecord: (() -> Void)? = nil
    /// The composer's voice recorder. Non-nil while the voice panel is open
    /// (after the quality picker confirms, until closed/removed/sent); nil
    /// hides the draft row and the mic button is the entry point.
    var voiceRecorder: VoiceMessageRecorder? = nil
    /// The shared voice player for the draft-row preview playback.
    var voicePlayer: VoiceMessagePlayer? = nil
    /// Start recording with the chosen profile (from the panel's Start row).
    var onVoiceStartRecording: ((VoiceMessageFormat) -> Void)? = nil
    /// Remove the selected draft recording.
    var onVoiceRemoveDraft: (() -> Void)? = nil
    /// Close the voice panel (return to the normal composer).
    var onVoiceClosePanel: (() -> Void)? = nil

    @AppStorage(ComposerKeyboardPreference.key)
    private var sendsOnReturn = ComposerKeyboardPreference.defaultValue

    // MARK: - Theme (delegates to Theme/ThemeManager)

    // MARK: - Computed Properties

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || attachedImage != nil
        || !attachedFiles.isEmpty
        || voiceDraftAudio != nil
    }

    /// The finalized, unsent voice recording (if any). nil while idle /
    /// recording / finalizing, so Send stays disabled until a draft exists.
    private var voiceDraftAudio: AudioAttachment? {
        guard let voiceRecorder else { return nil }
        if case .completed(let recording) = voiceRecorder.state {
            return recording.audio
        }
        return nil
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

            // Voice draft row (ready / recording / finalizing / selected).
            // Only present while the voice panel is open (the recorder is
            // passed through); when the panel is closed, nil hides it and
            // the mic button (in the action row) is the entry point.
            if let voiceRecorder, let voicePlayer {
                VoiceDraftRow(
                    recorder: voiceRecorder,
                    player: voicePlayer,
                    onStart: { format in onVoiceStartRecording?(format) },
                    onRemove: { onVoiceRemoveDraft?() },
                    onClose: { onVoiceClosePanel?() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .bottom, spacing: 12) {
                // Text field container
                HStack(alignment: .bottom, spacing: 8) {
                    // Text field
                    messageTextField
                }
                .background(Theme.backgroundTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Theme.divider, lineWidth: 0.5)
                )

                // Action buttons
                HStack(spacing: 12) {
                    // Voice message (mic) button — opens the quality picker and
                    // records a voice message. Hidden for callers that don't
                    // support voice (onVoiceRecord == nil).
                    if onVoiceRecord != nil {
                        Button(action: { onVoiceRecord?() }) {
                            Image(systemName: "mic")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        .accessibilityIdentifier("voice_message_button")
                        .accessibilityLabel(String(localized: "Record a voice message"))
                    }

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
                    // Stable identifiers so the Maestro interop harness
                    // (tests/interop/flows/) can target this button without
                    // resorting to brittle point-percent taps. Label
                    // doubles as VoiceOver narration ("Send message").
                    .accessibilityIdentifier("send_message_button")
                    .accessibilityLabel("Send message")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var messageTextField: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Type a message...")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            #if os(iOS)
            ComposerTextView(
                text: $text,
                sendsOnReturn: sendsOnReturn,
                onSubmit: {
                    if canSend {
                        onSend()
                    }
                }
            )
            .foregroundStyle(Theme.textPrimary)
            #else
            TextField("Type a message...", text: $text, axis: .vertical)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...6)
                .accessibilityIdentifier("message_composer")
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            #endif
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
