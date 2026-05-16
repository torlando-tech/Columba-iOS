//
//  CallControlButton.swift
//  ColumbaApp
//
//  Reusable circular control button for call screens.
//  Matches Android CallControlButton composable design.
//

import SwiftUI
import RNSAPI

/// Circular control button with icon, label, and active/inactive states.
@available(iOS 17.0, macOS 14.0, *)
struct CallControlButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isActive ? Theme.accentColor.opacity(0.3) : Color.white.opacity(0.1))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundStyle(isActive ? Theme.accentColor : .white)
                }

                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}
