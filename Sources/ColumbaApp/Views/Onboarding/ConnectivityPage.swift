#if COLUMBA_ONBOARDING_ENABLED
//
//  ConnectivityPage.swift
//  ColumbaApp
//
//  Onboarding page 2 (Model B): pick the community relay the node connects through.
//
//  Under Model B the Network Extension owns the node and its interfaces; the only
//  user-facing first-run choice that matters is which TCP relay to bootstrap from.
//  (The older multi-interface picker + in-app BLE/Bonjour permission probes were
//  removed: those interfaces live in the NE's own process, so prompting for them
//  here was misleading and the entities were ignored by the node.)
//

import SwiftUI
import RNSAPI

@available(iOS 17.0, macOS 14.0, *)
struct ConnectivityPage: View {
    @Binding var selectedTcpServer: TcpCommunityServer?
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var showServerPicker = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor)
                        .padding(.bottom, 24)

                    Text("Choose a relay")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)

                    Text("Columba reaches the wider network through a community relay server. We've picked a good default — you can change it anytime in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)

                    tcpServerRow
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)

                    Text("You can configure connectivity later in Settings")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
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
        .sheet(isPresented: $showServerPicker) {
            serverPickerSheet
        }
        .onAppear {
            // Preselect the default community server so a user who just taps through
            // still gets a reachable relay (the NE needs an enabled tcpClient).
            if selectedTcpServer == nil {
                selectedTcpServer = TcpCommunityServer.defaultServer
            }
        }
    }

    // MARK: - TCP Server Row

    private var tcpServerRow: some View {
        Button { showServerPicker = true } label: {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(Theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Relay server")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(selectedTcpServer?.name ?? "Select a server")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.textDisabled)
            }
            .padding(14)
            .background(Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Server Picker Sheet

    private var serverPickerSheet: some View {
        NavigationStack {
            List {
                Section("Bootstrap Servers") {
                    ForEach(TcpCommunityServer.servers.filter { $0.isBootstrap }) { server in
                        serverRow(server)
                    }
                }
                Section("Community Servers") {
                    ForEach(TcpCommunityServer.servers.filter { !$0.isBootstrap }) { server in
                        serverRow(server)
                    }
                }
            }
            .navigationTitle("Select Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showServerPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func serverRow(_ server: TcpCommunityServer) -> some View {
        Button {
            selectedTcpServer = server
            showServerPicker = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .foregroundStyle(.primary)
                    Text(server.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedTcpServer?.host == server.host && selectedTcpServer?.port == server.port {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accentColor)
                }
            }
        }
    }
}
#endif
