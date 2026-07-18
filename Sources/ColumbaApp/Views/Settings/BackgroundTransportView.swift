#if COLUMBA_RUNTIME_MODEL_B
//
//  BackgroundTransportView.swift
//  ColumbaApp
//
//  Opt-in explainer + enable/disable screen for the background transport
//  Network Extension (NEPacketTunnelProvider). Track C6 (UI portion).
//
//  This is an ADVANCED, opt-in feature: it requires a paid Apple Developer
//  account (the NE entitlement) and explicit user consent to install a local
//  VPN configuration profile. It is therefore presented as a dedicated
//  explainer screen reached from Settings (see `backgroundTransportCard` in
//  SettingsView) rather than forced into the mandatory onboarding flow.
//
//  The whole file is `COLUMBA_RUNTIME_MODEL_B`-gated because `TunnelManager`
//  belongs exclusively to the experimental Model B app.
//

import SwiftUI
import RNSAPI
import NetworkExtension

/// Explains the background transport in plain language and lets the user
/// enable (install + start) or disable (stop) the Network Extension tunnel.
///
/// Presented as a sheet from `SettingsView.backgroundTransportCard()`.
@available(iOS 17.0, macOS 14.0, *)
struct BackgroundTransportView: View {

    // MARK: - State

    /// The tunnel manager driving install/start/stop. `@Bindable` so the
    /// view re-renders as `TunnelManager.status` (an `@Observable` property)
    /// changes from the `NEVPNStatusDidChange` observer.
    @Bindable var tunnel: TunnelManager

    /// Set when `install()`/`start()` throws so we can surface the reason.
    @State private var errorMessage: String?

    /// True while an install/start round-trip is in flight (the user tapped
    /// Enable and we're awaiting `saveToPreferences` + the profile-install
    /// system prompt). Distinct from the `.connecting` VPN status, which only
    /// begins once the tunnel actually starts.
    @State private var isWorking = false

    /// Dismiss handler supplied by the presenter.
    let onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    statusCard
                    explainerCard
                    badgeCard
                    privacyCard
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    actionButton
                    Text("Requires installing a local VPN configuration. iOS will ask for your permission the first time you enable this.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Theme.backgroundPrimary)
            .navigationTitle("Background Transport")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Theme.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Stay reachable in the background")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Keep mesh delivery alive while Columba is closed or your phone is locked.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            Text(statusLabel)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if showsActivity {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accentColor)
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Explainer Card

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VPNExplainerUI.sectionHeader(icon: "questionmark.circle", title: "What it does")

            VPNExplainerUI.explainerRow(
                icon: "tray.and.arrow.down.fill",
                text: "Receives messages, calls, and announcements even when Columba isn't open."
            )
            VPNExplainerUI.explainerRow(
                icon: "point.3.connected.trianglepath.dotted",
                text: "Keeps your TCP and local-network (LAN) links connected to the Reticulum mesh in the background."
            )
            VPNExplainerUI.explainerRow(
                icon: "bolt.fill",
                text: "Uses more battery and data than running only in the foreground."
            )
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Status-Bar Badge Card

    private var badgeCard: some View {
        VPNBadgeExplainer(featureName: "background transport")
            .padding(16)
            .glassCard()
    }

    // MARK: - Privacy Card

    private var privacyCard: some View {
        VPNNotCommercialExplainer()
            .padding(16)
            .glassCard()
    }

    // MARK: - Error Card

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.error)
                Text("Couldn't enable")
                    .font(.headline)
                    .foregroundStyle(Theme.error)
            }

            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        if isEnabledState {
            // Disable: clear on-demand + stop (a bare stop() would auto-reconnect).
            Button {
                errorMessage = nil
                Task {
                    do { try await tunnel.disable() }
                    catch { errorMessage = error.localizedDescription }
                }
            } label: {
                Text("Disable Background Transport")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.error)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
            }
        } else {
            // Enable: install the profile (also arms on-demand) then start.
            Button {
                enable()
            } label: {
                Group {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Enable Background Transport")
                    }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
            }
            .disabled(isWorking)
        }
    }

    // MARK: - Actions

    private func enable() {
        errorMessage = nil
        isWorking = true
        Task {
            do {
                // install() saves/updates the VPN profile (triggering the iOS
                // permission prompt the first time) and arms on-demand connect;
                // start() then brings the tunnel up. start() itself falls back
                // to install() if no manager is loaded, but we call install()
                // explicitly so the profile is (re)written with the current
                // on-demand rules before starting.
                try await tunnel.install()
                try await tunnel.start()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    // MARK: - Status Derivation

    /// Whether the tunnel is in an "on" state from the user's perspective —
    /// connected, mid-connect, reasserting, or installed-and-enabled. Used to
    /// flip the primary action between Enable and Disable.
    private var isEnabledState: Bool {
        switch tunnel.status {
        case .connected, .connecting, .reasserting, .disconnecting:
            return true
        case .disconnected, .invalid:
            return false
        @unknown default:
            return tunnel.isEnabled
        }
    }

    private var showsActivity: Bool {
        if isWorking { return true }
        switch tunnel.status {
        case .connecting, .reasserting, .disconnecting:
            return true
        default:
            return false
        }
    }

    private var statusLabel: String {
        if isWorking { return "Installing…" }
        switch tunnel.status {
        case .invalid:
            return "Not configured"
        case .disconnected:
            return "Off"
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Active"
        case .reasserting:
            return "Reconnecting…"
        case .disconnecting:
            return "Disconnecting…"
        @unknown default:
            return tunnel.isEnabled ? "Enabled" : "Off"
        }
    }

    private var statusColor: Color {
        if isWorking { return Theme.warning }
        switch tunnel.status {
        case .connected:
            return Theme.success
        case .connecting, .reasserting, .disconnecting:
            return Theme.warning
        case .invalid:
            return Theme.error
        case .disconnected:
            return Theme.textSecondary
        @unknown default:
            return Theme.textSecondary
        }
    }

}
#endif
