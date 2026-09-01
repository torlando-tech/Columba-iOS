//
//  VoiceMessageBubble.swift
//  ColumbaApp
//
//  The timeline rendering of a received/sent voice message (field 7). Ports
//  Android Columba's `VoiceMessageBubble` (`VoiceMessageComponents.kt`, the
//  `message_voice_*` strings) state-for-state:
//
//     title "Voice message"
//     when:
//       loading                  -> "Loading voice message"
//       error == "unsupported"   -> "Unsupported voice message"
//       error != null            -> "Voice message unavailable"
//       else                     -> play/pause + waveform + "X of Y"
//
//  Playback is driven by a `VoiceMessagePlayer` (shared across the timeline,
//  one per conversation screen). A message's player key is its message id, so
//  at most one voice message plays at a time (the player cancels the prior
//  when a new one starts).
//

import SwiftUI
import RNSAPI

/// The voice-message bubble shown in the chat timeline for a message that has
/// a field-7 `AudioAttachment`.
public struct VoiceMessageBubble: View {
    let message: Message
    let isFromMe: Bool
    let player: VoiceMessagePlayer

    public init(message: Message, player: VoiceMessagePlayer) {
        self.message = message
        self.isFromMe = message.isFromMe
        self.player = player
    }

    private var key: String { message.id }

    public var body: some View {
        if let attachment = message.audioAttachment {
            // `.custom` (an unrecognized wire mode) is non-playable: map it to
            // the player's "unsupported" error state, exactly as Android maps
            // a missing player (`VoiceMessagePlayerState(error = "unsupported")`).
            if attachment.mode == .custom {
                stateView(errorMessage: "unsupported")
            } else {
                playableRow(attachment)
            }
        }
    }

    // MARK: - Playable row (Android: the else branch)

    @ViewBuilder
    private func playableRow(_ attachment: AudioAttachment) -> some View {
        let state = player.state(for: key)
        let duration = state.durationMs > 0
            ? state.durationMs
            : (attachment.durationMs ?? Int(attachment.durationSeconds * 1000))
        let progressFraction: CGFloat = duration > 0
            ? CGFloat(state.positionMs) / CGFloat(duration)
            : 0
        let waveform = player.waveform(for: key) ?? VoiceWaveform.placeholder()
        let isPlaying = state.status == .playing

        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Voice message"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("voice_bubble_title")

            if state.status == .loading {
                Text(String(localized: "Loading voice message"))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("voice_bubble_loading")
            } else if let err = state.errorMessage {
                stateView(errorMessage: err)
            } else {
                HStack(spacing: 12) {
                    Button {
                        player.prepare(key: key, attachment: attachment)
                        player.togglePlay(key: key, attachment: attachment)
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Theme.accentColor)
                    }
                    .accessibilityLabel(
                        isPlaying
                            ? String(localized: "Pause voice message")
                            : String(localized: "Play voice message")
                    )
                    .accessibilityIdentifier("voice_bubble_play")

                    VoiceWaveformBars(peaks: waveform, progress: progressFraction)
                        .accessibilityHidden(true)

                    Text(progressText(state.positionMs, duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("Playback progress")
                        .accessibilityIdentifier("voice_bubble_progress")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isFromMe ? Color.clear : Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Unsupported / unavailable (Android: the error branches)

    @ViewBuilder
    private func stateView(errorMessage: String?) -> some View {
        Text(
            errorMessage == "unsupported"
                ? String(localized: "Unsupported voice message")
                : String(localized: "Voice message unavailable")
        )
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(2)
        .accessibilityIdentifier(
            errorMessage == "unsupported"
                ? "voice_bubble_unsupported"
                : "voice_bubble_unavailable"
        )
    }

    // MARK: - Formatting

    private func formatTime(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func progressText(_ currentMs: Int, _ totalMs: Int) -> String {
        let current = formatTime(currentMs)
        let total = totalMs > 0 ? formatTime(totalMs) : "--:--"
        return String(format: String(localized: "%@ of %@"), current, total)
    }
}

/// A non-playable voice-attachment indicator, used when a bubble has a field-7
/// attachment but no player is wired (e.g. a preview context).
public struct VoiceMessageBubbleUnavailable: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(String(localized: "Voice message unavailable"))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("voice_bubble_unavailable")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
