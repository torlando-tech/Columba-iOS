//
//  BackgroundTransportPage.swift
//  ColumbaApp
//
//  Onboarding page 3: Background Transport opt-in. Pre-checked ON
//  by default; lets the user opt out before completing onboarding.
//  Drives `tunnel_enabled` in the App Group UserDefaults, which
//  AppServices.initialize() reads to auto-start the Network Extension.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct BackgroundTransportPage: View {
    @Binding var enabled: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accentColor)
                .padding(.bottom, 24)

            Text("Stay Connected in the Background")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            Text("Keep messages flowing while your phone is locked.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 14) {
                featureRow("Receive messages over the internet (TCP) when locked")
                featureRow("Voice calls ring even when the app is closed")
                featureRow("Reconnects automatically across networks")
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 16)

            Text("Auto Discovery and Nearby only work while the app is open — iOS doesn't allow extensions to send LAN packets in the background.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 16)

            // Toggle card
            HStack(spacing: 14) {
                Image(systemName: enabled ? "checkmark.shield.fill" : "shield")
                    .font(.system(size: 24))
                    .foregroundStyle(enabled ? Theme.success : Theme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Transport")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Recommended on")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .tint(Theme.accentColor)
            }
            .padding(16)
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(enabled ? Theme.success.opacity(0.5) : Theme.divider, lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Text("iOS will ask you to install a VPN profile to allow this. You can change it anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

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

    private func featureRow(_ text: String) -> some View {
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
