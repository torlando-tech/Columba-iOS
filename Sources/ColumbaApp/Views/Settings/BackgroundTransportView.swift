import SwiftUI
import NetworkExtension

/// A single app offers two process hosts. Selection applies at the next launch
/// so interfaces are never moved between live Python interpreters.
@available(iOS 17.0, macOS 14.0, *)
struct BackgroundTransportView: View {
    @Bindable var tunnel: TunnelManager
    let activeHost: NodeHostingMode
    let onDismiss: () -> Void
    @State private var selectedHost = NodeHostingMode.selected
    @State private var showDetail = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Reticulum Hosting").font(.title2.bold())
                    Picker("Host", selection: $selectedHost) {
                        Text("Background").tag(NodeHostingMode.networkExtension)
                        Text("Foreground Only").tag(NodeHostingMode.foreground)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedHost) { _, mode in
                        SharedDefaults.suite.set(mode.rawValue, forKey: NodeHostingMode.preferenceKey)
                    }

                    Text("Background hosting is recommended")
                        .font(.headline)
                    Text("Columba can receive messages while the app is suspended. Keeping Reticulum running also avoids reconnects and interrupted listeners when you leave the app.")
                    Text("iOS uses a local VPN configuration to keep this network component running. Columba does not route other apps or web traffic through it. iOS asks for permission when you first enable it.")

                    Text("Foreground only").font(.headline)
                    Text("Use this mode if you cannot or prefer not to use the VPN configuration. Reticulum runs inside Columba, and its connections stop working while iOS suspends the app. Incoming messages may be delayed until you return.")

                    if selectedHost != activeHost {
                        Text("Saved. Close and reopen Columba to change hosts.")
                            .font(.headline).foregroundStyle(Theme.accentColor)
                    }
                    Text("Hosting changes take effect on a fresh app launch. Switching away from background mode also disables the VPN's automatic reconnection.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)

                    // Full-width "Learn more" — pushes the detailed VPN explainer
                    // (what it does, the status-bar badge, "not a commercial VPN")
                    // that was part of the original Background Transport screen.
                    Button {
                        showDetail = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14, weight: .medium))
                            Text(String(localized: "Learn more"))
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.backgroundTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .background(Theme.backgroundPrimary)
            .foregroundStyle(Theme.textPrimary)
            .navigationTitle("Reticulum Hosting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
            .navigationDestination(isPresented: $showDetail) {
                BackgroundTransportDetail()
            }
        }
    }
}

/// The detailed VPN explainer, reusing the shared `VPNExplainerUI` primitives and
/// the `VPNBadgeExplainer` / `VPNNotCommercialExplainer` components so the copy
/// stays identical to the onboarding Background Delivery page. Pushed from the
/// "Learn more" button in `BackgroundTransportView`.
@available(iOS 17.0, macOS 14.0, *)
struct BackgroundTransportDetail: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                whatItDoesCard
                VPNBadgeExplainer()
                    .padding(16)
                    .glassCard()
                VPNNotCommercialExplainer()
                    .padding(16)
                    .glassCard()
            }
            .padding(16)
        }
        .background(Theme.backgroundPrimary)
        .foregroundStyle(Theme.textPrimary)
        .navigationTitle(String(localized: "Background Hosting"))
        .navigationBarTitleDisplayMode(.inline)
    }

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
                    Text(String(localized: "Stay reachable in the background"))
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(localized: "Keep mesh delivery alive while Columba is closed or your phone is locked."))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    private var whatItDoesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VPNExplainerUI.sectionHeader(icon: "questionmark.circle", title: String(localized: "What it does"))

            VPNExplainerUI.explainerRow(
                icon: "tray.and.arrow.down.fill",
                text: String(localized: "Receives messages, calls, and announcements even when Columba isn't open.")
            )
            VPNExplainerUI.explainerRow(
                icon: "point.3.connected.trianglepath.dotted",
                text: String(localized: "Keeps you connected to the Reticulum network in the background.")
            )
        }
        .padding(16)
        .glassCard()
    }
}
