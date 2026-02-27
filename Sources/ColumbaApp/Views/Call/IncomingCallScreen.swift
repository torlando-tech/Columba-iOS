//
//  IncomingCallScreen.swift
//  ColumbaApp
//
//  Incoming call screen presented as fullScreenCover.
//  Matches Android IncomingCallScreen.kt layout with pulsing avatar
//  and answer/decline buttons.
//

import SwiftUI

/// Full-screen incoming call interface with answer and decline options.
@available(iOS 17.0, macOS 14.0, *)
struct IncomingCallScreen: View {
    let callManager: CallManager
    var onAnswer: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                // Pulsing avatar
                ZStack {
                    // Outer pulse ring
                    Circle()
                        .fill(Theme.accentColor.opacity(0.1))
                        .frame(width: 160, height: 160)
                        .scaleEffect(pulseScale)

                    // Inner avatar
                    ZStack {
                        Circle()
                            .fill(Theme.accentColor.opacity(0.15))
                            .frame(width: 120, height: 120)

                        Image(systemName: "person.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Theme.accentColor)
                    }
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulseScale = 1.1
                    }
                }

                Spacer().frame(height: 24)

                // Caller name
                Text(callManager.peerName ?? callManager.peerHash ?? "Unknown")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Spacer().frame(height: 8)

                Text("Incoming Voice Call")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Answer / Decline buttons
                HStack(spacing: 80) {
                    // Decline
                    VStack(spacing: 8) {
                        Button {
                            callManager.hangup()
                            dismiss()
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

                        Text("Decline")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    // Answer
                    VStack(spacing: 8) {
                        Button {
                            callManager.answerCall()
                            onAnswer()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: "4CAF50"))
                                    .frame(width: 72, height: 72)

                                Image(systemName: "phone.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white)
                            }
                        }

                        Text("Answer")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .onChange(of: callManager.callState) { _, newState in
            switch newState {
            case .idle, .ended:
                dismiss()
            case .connecting, .established:
                // Call was answered (possibly via CallKit notification).
                // Dismiss incoming screen and transition to active call screen.
                onAnswer()
            default:
                break
            }
        }
    }
}
