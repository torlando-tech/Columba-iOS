#if COLUMBA_ONBOARDING_ENABLED
//
//  BackgroundDeliveryPage.swift
//  ColumbaApp
//
//  Onboarding step 5 (Model B): enable background delivery by bringing up the
//  on-device VPN / Network Extension that owns the Reticulum/LXMF node.
//
//  This is a real step IN the flow (before the Complete page): the app creates +
//  shares the identity and installs/starts the tunnel here, so by the time the user
//  finishes onboarding the node is already up. `onEnable` returns whether the tunnel
//  connected (iOS shows its "Allow" VPN prompt during it); on failure the page shows
//  an error and lets the user retry rather than advancing.
//
//  The "Not a commercial VPN" + "VPN badge" explainer cards reuse the shared
//  `VPNNotCommercialExplainer` / `VPNBadgeExplainer` content (see
//  BackgroundVPNExplainer.swift) — the same copy shown on the settings Background
//  Transport screen — so users understand up front that this isn't a traditional /
//  commercial VPN, just Apple's VPN mechanism hosting the on-device mesh node.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct BackgroundDeliveryPage: View {
    /// Performs the enable (create+share identity, install+start tunnel, wait for
    /// connect). Returns success; advancing to the next page is the caller's job on
    /// `true`.
    let onEnable: () async -> Bool
    let onBack: () -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    ZStack {
                        Circle()
                            .fill(Theme.accentColor.opacity(0.15))
                            .frame(width: 110, height: 110)
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(Theme.accentColor)
                    }
                    .padding(.bottom, 24)

                    Text("Background Delivery")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)

                    Text("Columba runs a small on-device VPN so it can keep delivering and receiving your messages in the background — even when the app is closed. Your traffic isn't sent to any server; the tunnel only powers Columba's own network node on your device.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 16)

                    privacyCard
                    badgeCard

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Theme.error)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 8)
                    }

                    Text("iOS will ask you to allow the VPN configuration. Columba can't deliver messages in the background without it.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                }
            }

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
                .disabled(isWorking)

                Button {
                    enable()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(isWorking ? "Connecting…" : (errorMessage == nil ? "Enable" : "Try Again"))
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isWorking)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private func enable() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let ok = await onEnable()
            isWorking = false
            if !ok {
                errorMessage = "Couldn't enable background delivery. Make sure you tapped “Allow” on the VPN prompt, then try again."
            }
            // On success the caller advances to the next page.
        }
    }

    // MARK: - Explainer Cards

    /// "Not a commercial VPN" reassurance — the core message that this isn't a
    /// traditional VPN. Content is shared with the settings Background Transport
    /// screen via `VPNNotCommercialExplainer`; only the card chrome differs (onboarding
    /// `explainerCardStyle` here vs the settings `glassCard()`).
    private var privacyCard: some View {
        VPNNotCommercialExplainer()
            .explainerCardStyle()
    }

    /// "The VPN badge" note, shared with settings via `VPNBadgeExplainer`. The feature
    /// name reads "background delivery" to match this flow (settings says "background
    /// transport").
    private var badgeCard: some View {
        VPNBadgeExplainer(featureName: "background delivery")
            .explainerCardStyle()
    }
}

/// Shared card chrome for the onboarding explainer cards — matches the
/// `Theme.backgroundSecondary` card style used elsewhere in onboarding
/// (e.g. `PermissionsPage`) rather than the settings `glassCard()`.
@available(iOS 17.0, macOS 14.0, *)
private extension View {
    func explainerCardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.divider, lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
    }
}
#endif
