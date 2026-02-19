//
//  PttButton.swift
//  ColumbaApp
//
//  Hold-to-talk push-to-talk button for voice calls.
//  Matches Android PttButton composable design.
//

import SwiftUI

/// Large circular push-to-talk button with press/release detection.
@available(iOS 17.0, macOS 14.0, *)
struct PttButton: View {
    @Binding var isActive: Bool
    var onActivate: (Bool) -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Theme.accentColor.opacity(0.3) : Color.white.opacity(0.08))
                .frame(width: 140, height: 140)
                .scaleEffect(isActive ? 1.1 : 1.0)

            Circle()
                .stroke(isActive ? Theme.accentColor : Color.white.opacity(0.2), lineWidth: 2)
                .frame(width: 140, height: 140)
                .scaleEffect(isActive ? 1.1 : 1.0)

            VStack(spacing: 8) {
                Image(systemName: isActive ? "mic.fill" : "mic")
                    .font(.system(size: 40))
                    .foregroundStyle(isActive ? Theme.accentColor : .white)

                Text(isActive ? "TALKING" : "HOLD\nTO TALK")
                    .font(.system(size: 12, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isActive ? Theme.accentColor : .white.opacity(0.7))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isActive {
                        isActive = true
                        onActivate(true)
                    }
                }
                .onEnded { _ in
                    isActive = false
                    onActivate(false)
                }
        )
    }
}
