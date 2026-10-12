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
                }
                .padding(20)
            }
            .background(Theme.backgroundPrimary)
            .foregroundStyle(Theme.textPrimary)
            .navigationTitle("Reticulum Hosting")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}
