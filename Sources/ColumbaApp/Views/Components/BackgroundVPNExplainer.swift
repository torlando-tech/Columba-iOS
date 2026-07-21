#if COLUMBA_RUNTIME_MODEL_B
//
//  BackgroundVPNExplainer.swift
//  ColumbaApp
//
//  Canonical "this isn't a traditional / commercial VPN" explainer content, shared by
//  the Settings → Background Transport screen (`BackgroundTransportView`) and the
//  onboarding Background Delivery page (`BackgroundDeliveryPage`) so the wording and
//  layout stay identical and only live in one place.
//
//  These are inner-content views only — they intentionally carry NO card chrome. Each
//  call site wraps them in its own card style (settings uses `.glassCard()`, onboarding
//  uses a `Theme.backgroundSecondary` card) so the explainer reads natively in either
//  surface while the copy stays single-sourced here.
//

import SwiftUI

/// "Not a commercial VPN" privacy reassurance — the core message that this is only
/// Apple's VPN mechanism hosting the on-device mesh node, not a traditional VPN.
@available(iOS 17.0, macOS 14.0, *)
struct VPNNotCommercialExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VPNExplainerUI.sectionHeader(icon: "lock.shield.fill", title: "Not a commercial VPN")

            Text("Columba uses Apple's VPN system to keep its own network component available in the background. It is not a commercial VPN service.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VPNExplainerUI.explainerRow(
                icon: "checkmark.shield.fill",
                text: "Your other apps and web traffic are not proxied or routed through Columba."
            )
            VPNExplainerUI.explainerRow(
                icon: "iphone",
                text: "The component carries Columba and Reticulum traffic, which may use the relay and interfaces you configured."
            )
        }
    }
}

/// "The VPN badge" explainer — pre-empts the iOS status-bar VPN badge, the thing that
/// makes the feature look like a traditional VPN. `featureName` fills the trailing
/// sentence so each surface uses its own term ("background transport" vs "delivery").
@available(iOS 17.0, macOS 14.0, *)
struct VPNBadgeExplainer: View {
    let featureName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VPNExplainerUI.sectionHeader(icon: "rectangle.topthird.inset.filled", title: "The VPN indicator")

            HStack(spacing: 10) {
                Text("VPN")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text("While this is on, iOS shows a VPN indicator.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The indicator means iOS has an active network extension. It stays visible while \(featureName) is enabled.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shared section-header / explainer-row primitives used by the explainer content
/// above. Kept here so both surfaces (and the settings "What it does" card) render
/// rows identically.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
enum VPNExplainerUI {
    static func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accentColor)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
    }

    static func explainerRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
#endif
