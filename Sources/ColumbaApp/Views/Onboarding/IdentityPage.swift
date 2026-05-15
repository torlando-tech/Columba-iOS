#if COLUMBA_ONBOARDING_ENABLED
//
//  IdentityPage.swift
//  ColumbaApp
//
//  Onboarding page 1: Display name entry.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct IdentityPage: View {
    @Binding var displayName: String
    let onBack: () -> Void
    let onContinue: () -> Void

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "person.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accentColor)
                .padding(.bottom, 24)

            Text("Your Identity")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            Text("Choose a display name others will see:")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 32)

            // Name field
            TextField("Anonymous Peer", text: $displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .padding(16)
                .background(Theme.backgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isNameFocused ? Theme.accentColor : Theme.divider, lineWidth: 1)
                )
                .focused($isNameFocused)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            Text("You can change this anytime, or create multiple identities for different contexts.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            // Navigation buttons
            HStack(spacing: 16) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button(action: onContinue) {
                    HStack(spacing: 6) {
                        Text("Continue")
                        Image(systemName: "chevron.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .onTapGesture { isNameFocused = false }
    }
}
#endif
