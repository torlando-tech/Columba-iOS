//
//  VoiceCallScreen.swift
//  ColumbaApp
//
//  Active/outgoing voice call screen presented as fullScreenCover.
//  Matches Android VoiceCallScreen.kt layout with avatar, status,
//  call controls, and PTT button.
//

import SwiftUI

/// Full-screen voice call interface for active and outgoing calls.
@available(iOS 17.0, macOS 14.0, *)
struct VoiceCallScreen: View {
    let callManager: CallManager
    let peerName: String
    let destinationHash: Data

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Avatar
                avatarSection

                Spacer().frame(height: 12)

                // Peer name
                Text(peerName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer().frame(height: 8)

                // Status text
                statusText
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // PTT button (when PTT mode is on and call is established)
                if callManager.isPttMode && callManager.callState == .established {
                    PttButton(
                        isActive: Binding(
                            get: { callManager.isPttActive },
                            set: { callManager.setPttActive($0) }
                        ),
                        onActivate: { active in
                            callManager.setPttActive(active)
                        }
                    )
                    Spacer()
                }

                // Controls row
                controlsRow
                    .padding(.bottom, 24)

                // End call button
                endCallButton
                    .padding(.bottom, 60)
            }
        }
        .onChange(of: callManager.callState) { _, newState in
            if case .idle = newState {
                dismiss()
            }
        }
    }

    // MARK: - Subviews

    private var avatarSection: some View {
        ZStack {
            Circle()
                .fill(Theme.accentColor.opacity(0.15))
                .frame(width: 120, height: 120)

            Image(systemName: "person.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accentColor)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch callManager.callState {
        case .calling:
            Text("Calling...")
        case .ringing:
            Text("Ringing...")
        case .connecting:
            Text("Connecting...")
        case .established:
            Text(callManager.formattedDuration)
        case .ended(let reason):
            Text(reason)
        case .busy:
            Text("Busy")
        case .idle:
            Text("")
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 32) {
            CallControlButton(
                icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                label: "Mute",
                isActive: callManager.isMuted,
                enabled: callManager.callState == .established,
                action: { callManager.toggleMute() }
            )

            CallControlButton(
                icon: callManager.isPttMode ? "hand.raised.fill" : "hand.raised",
                label: "PTT",
                isActive: callManager.isPttMode,
                enabled: callManager.callState == .established,
                action: { callManager.togglePttMode() }
            )

            CallControlButton(
                icon: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                label: "Speaker",
                isActive: callManager.isSpeakerOn,
                enabled: callManager.callState == .established,
                action: { callManager.toggleSpeaker() }
            )
        }
    }

    private var endCallButton: some View {
        Button {
            callManager.hangup()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 72, height: 72)

                Image(systemName: "phone.down.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
        }
    }
}
