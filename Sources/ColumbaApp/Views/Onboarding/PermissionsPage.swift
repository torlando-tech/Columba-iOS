#if COLUMBA_ONBOARDING_ENABLED
//
//  PermissionsPage.swift
//  ColumbaApp
//
//  Onboarding page 3: Notification permission request.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct PermissionsPage: View {
    let notificationsGranted: Bool
    let onRequestNotifications: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "bell.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accentColor)
                .padding(.bottom, 24)

            Text("Stay Connected")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            Text("Columba can notify you when:")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 24)

            // Notification features
            VStack(alignment: .leading, spacing: 14) {
                notificationRow("New messages arrive")
                notificationRow("Incoming voice calls")
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)

            // Permission card
            HStack(spacing: 14) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(notificationsGranted ? Theme.success : Theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Push Notifications")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(notificationsGranted ? "Enabled" : "Allow notifications to stay informed")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                if notificationsGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.success)
                } else {
                    Button(action: onRequestNotifications) {
                        Text("Enable")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Theme.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(notificationsGranted ? Theme.success.opacity(0.5) : Theme.divider, lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Text("You can change notification settings anytime in iOS Settings")
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
    }

    private func notificationRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24)

            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
#endif
