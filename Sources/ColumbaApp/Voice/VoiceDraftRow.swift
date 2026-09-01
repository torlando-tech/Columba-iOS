//
//  VoiceDraftRow.swift
//  ColumbaApp
//
//  The composer's voice-message panel, shown above the text input while the
//  user is recording, finalizing, or has a recorded-but-unsent draft. Ports
//  Android Columba's `VoiceMessagePanel` (`VoiceMessageComponents.kt`, the
//  `attachment_voice_panel_*` strings) state-for-state:
//
//   - not supported:   "Voice messages are not supported on this device." + Close.
//   - blocked by call: "Voice recording is unavailable during a call." + Close.
//   - no permission:   permission-needed (or permanently-denied) text +
//                      "Grant microphone access" / "Open settings" + Close.
//   - ready:           mic + "Ready to record a voice message" (+ the last
//                      error, if any) + filled Start + Close. The panel's idle
//                      state; on Android the panel is open after the quality
//                      dialog confirms and Start begins recording with the
//                      chosen format.
//   - recording:       red dot + "Recording" + elapsed, Cancel (trash icon),
//                      filled Stop.
//   - finalizing:      spinner + "Finalizing" + Close.
//   - selected:        draft preview (play toggle, waveform, "X of Y", remove,
//                      Close) - Android's `VoiceDraftPreview`.
//
//  The panel is a single compact, bottom-anchored surface, matching Android's
//  layout. Exact user-facing text comes from `Localizable.xcstrings`
//  (Section 3 of the voice-messages parity plan); the static contract test
//  asserts the literal values.
//

import SwiftUI
import RNSAPI
import AVFoundation

/// The voice composer panel. Driven by a `VoiceMessageRecorder`'s observable
/// state plus the mic-permission and call-active inputs the recorder does not
/// model (those are app-level, checked here exactly as Android checks them in
/// `MessagingScreen`).
@available(iOS 17.0, *)
public struct VoiceDraftRow: View {
    let recorder: VoiceMessageRecorder
    let player: VoiceMessagePlayer
    /// True while a voice call is active (blocks recording, as on Android).
    var isCallActive: Bool = false
    var onStart: (VoiceMessageFormat) -> Void
    var onRemove: () -> Void
    var onClose: () -> Void

    @State private var permissionBump = 0

    // MARK: - Permission (app-level, mirrors Android's ContextCompat check)

    private var micPermission: AVAudioSession.RecordPermission {
        AVAudioSession.sharedInstance().recordPermission()
    }

    private var hasPermission: Bool { micPermission == .granted }

    private var permissionPermanentlyDenied: Bool { micPermission == .denied }

    public init(
        recorder: VoiceMessageRecorder,
        player: VoiceMessagePlayer,
        isCallActive: Bool = false,
        onStart: @escaping (VoiceMessageFormat) -> Void,
        onRemove: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.recorder = recorder
        self.player = player
        self.isCallActive = isCallActive
        self.onStart = onStart
        self.onRemove = onRemove
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if case .completed(let recording) = recorder.state {
                previewPanel(recording)
            } else {
                switch recorder.state {
                case .recording(let elapsedMs):
                    recordingPanel(elapsedMs: elapsedMs)
                case .finalizing:
                    finalizingPanel
                default:
                    // idle / failed: the "ready" row (+ the last error, if any).
                    readyPanel
                }
            }
        }
        // Re-evaluate the permission-based rows after a permission request
        // resolves (the audio session does not publish the change itself).
        .id(permissionBump)
    }

    // MARK: - Recording

    private func recordingPanel(elapsedMs: Int) -> some View {
        HStack(spacing: 12) {
            Button(action: { recorder.cancel() }) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.red)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(String(localized: "Cancel recording"))
            .accessibilityIdentifier("voice_panel_cancel")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text(String(localized: "Recording"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.red)
                        .accessibilityIdentifier("voice_panel_recording")
                }
                Text(formatElapsed(elapsedMs))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityLabel("Recording elapsed time")
                    .accessibilityIdentifier("voice_panel_elapsed")
            }
            .accessibilityElement(children: .combine)

            Spacer()

            Button(action: { recorder.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentColor, in: Circle())
            }
            .accessibilityLabel(String(localized: "Stop recording"))
            .accessibilityIdentifier("voice_panel_stop")
        }
        .panelSurface()
    }

    // MARK: - Finalizing

    private var finalizingPanel: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Finalizing"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("voice_panel_finalizing")
                Text("--:--")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            closeButton
        }
        .panelSurface()
    }

    // MARK: - Ready / unsupported / call / permission

    @ViewBuilder
    private var readyPanel: some View {
        let errorText = recorder.errorMessage
        if recorder.lastFailureWasUnsupported {
            unsupportedRow
        } else if isCallActive {
            callActiveRow
        } else if !hasPermission {
            permissionRow
        } else {
            readyRow(errorText: errorText)
        }
    }

    private var unsupportedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(String(localized: "Voice messages are not supported on this device."))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("voice_panel_unsupported")
            Spacer()
            closeButton
        }
        .panelSurface()
    }

    private var callActiveRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(String(localized: "Voice recording is unavailable during a call."))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("voice_panel_call_active")
            Spacer()
            closeButton
        }
        .panelSurface()
    }

    private var permissionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accentColor)
                .accessibilityHidden(true)
            if permissionPermanentlyDenied {
                Text(String(localized: "Microphone access is disabled. Enable it in app settings."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier("voice_panel_permission_settings")
            } else {
                Text(String(localized: "Microphone permission is required to record a voice message."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier("voice_panel_permission_needed")
            }
            Spacer()
            Button {
                if permissionPermanentlyDenied {
                    openAppSettings()
                } else {
                    Task {
                        // Awaits the user's response to the system prompt
                        // before returning (iOS 17+ API).
                        _ = await AVAudioApplication.requestRecordPermission()
                        // The session does not publish permission changes;
                        // change the panel's id so the whole row re-evaluates
                        // `hasPermission` with the fresh value.
                        permissionBump &+= 1
                    }
                }
            } label: {
                Text(permissionPermanentlyDenied
                     ? String(localized: "Open settings")
                     : String(localized: "Grant microphone access"))
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityIdentifier("voice_panel_request_permission")
            closeButton
        }
        .panelSurface()
    }

    private func readyRow(errorText: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Ready to record a voice message"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("voice_panel_ready")
                if let errorText {
                    Text(String(localized: "Recording error: %@", errorText))
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .lineLimit(2)
                        .accessibilityIdentifier("voice_panel_error")
                }
            }
            Spacer()
            Button {
                onStart(recorder.selectedFormat ?? .defaultFormat)
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accentColor, in: Circle())
            }
            .accessibilityLabel(String(localized: "Start recording"))
            .accessibilityIdentifier("voice_panel_start")
            closeButton
        }
        .panelSurface()
    }

    // MARK: - Selected draft preview

    private func previewPanel(_ recording: VoiceRecording) -> some View {
        let attachment = recording.audio
        let key = recording.url.path
        let state = player.state(for: key)
        let duration = state.durationMs > 0
            ? state.durationMs
            : (recording.durationMs > 0 ? recording.durationMs : Int(attachment.durationSeconds * 1000))
        let progress: CGFloat = duration > 0 ? CGFloat(state.positionMs) / CGFloat(duration) : 0
        let waveform = player.waveform(for: key) ?? VoiceWaveform.placeholder()
        let isPlaying = state.status == .playing

        return VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Voice message"))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("voice_panel_title")
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
                .accessibilityIdentifier("voice_panel_play")

                VoiceWaveformBars(peaks: waveform, progress: progress)
                    .accessibilityHidden(true)

                Text(progressText(state.positionMs, duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Playback progress")
                    .accessibilityIdentifier("voice_panel_progress")

                Spacer()

                Button(action: {
                    player.stopCurrent()
                    onRemove()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel(String(localized: "Remove recording"))
                .accessibilityIdentifier("voice_panel_remove")
            }
        }
        .panelSurface()
        .onDisappear {
            // Leaving the panel must not keep a preview playing.
            player.stopCurrent()
        }
    }

    // MARK: - Shared pieces

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34, height: 34)
        }
        .accessibilityLabel("Close")
        .accessibilityIdentifier("voice_panel_close")
    }

    // MARK: - Actions

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Formatting

    private func formatElapsed(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func progressText(_ currentMs: Int, _ totalMs: Int) -> String {
        let current = formatElapsed(currentMs)
        let total = totalMs > 0 ? formatElapsed(totalMs) : "--:--"
        return String(localized: "%@ of %@", current, total)
    }
}

private extension View {
    /// The shared panel surface (background + rounded corners).
    func panelSurface() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
