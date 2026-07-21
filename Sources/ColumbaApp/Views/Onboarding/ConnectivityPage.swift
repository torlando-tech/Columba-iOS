#if COLUMBA_ONBOARDING_ENABLED
//
//  ConnectivityPage.swift
//  ColumbaApp
//
//  Onboarding page 2: shipping builds choose interfaces; Model B chooses its relay.
//

import SwiftUI
import RNSAPI

@available(iOS 17.0, macOS 14.0, *)
struct ConnectivityPage: View {
    @Binding var selectedInterfaces: Set<OnboardingInterfaceType>
    @Binding var selectedTcpServer: TcpCommunityServer?
    let isReadOnly: Bool
    let onRequestBluetooth: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var showServerPicker = false

    var body: some View {
        #if COLUMBA_RUNTIME_MODEL_B
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor)
                        .padding(.bottom, 24)

                    Group {
                        if isReadOnly {
                            Text("Current relay")
                        } else {
                            Text("Choose a relay")
                        }
                    }
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)

                    Group {
                        if isReadOnly {
                            Text("This is the relay currently configured for Columba. You can change it later in Settings.")
                        } else {
                            Text("A relay helps your device reach Reticulum peers over the internet. It transports encrypted Reticulum traffic — it does not create an account or hold your identity. We've selected a recommended default.")
                        }
                    }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)

                    tcpServerRow
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)

                    Text("You can choose another relay later in Settings.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 16)
                }
            }

            navigationButtons
        }
        .sheet(isPresented: $showServerPicker) {
            serverPickerSheet
        }
        .onAppear {
            if !isReadOnly && selectedTcpServer == nil {
                selectedTcpServer = TcpCommunityServer.defaultServer
            }
        }
        #else
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor)
                        .padding(.bottom, 24)

                    Group {
                        if isReadOnly {
                            Text("Current connections")
                        } else {
                            Text("How will you connect?")
                        }
                    }
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)

                    Group {
                        if isReadOnly {
                            Text("This setup review is read-only. Change connection methods in Settings.")
                        } else {
                            Text("Select one or more. You can change these later.")
                        }
                    }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 24)

                    VStack(spacing: 12) {
                        // MultipeerConnectivity has no shipping Python transport yet.
                        // Keep the enum/config case for compatibility, but do not offer
                        // a choice that cannot create a working interface.
                        ForEach(OnboardingInterfaceType.allCases.filter { $0 != .nearby }, id: \.self) { type in
                            interfaceCard(type)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                    if selectedInterfaces.contains(.tcp) {
                        tcpServerRow
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    }

                    if !isReadOnly && selectedInterfaces.isEmpty {
                        Text("Select at least one connection method to continue.")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.warning)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 8)
                    }

                    Text("Bluetooth access is requested only if you select Bluetooth LE. RNode access is requested later during radio setup.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                }
            }

            navigationButtons
        }
        .sheet(isPresented: $showServerPicker) {
            serverPickerSheet
        }
        .onAppear {
            if !isReadOnly && selectedInterfaces.contains(.tcp) && selectedTcpServer == nil {
                selectedTcpServer = TcpCommunityServer.defaultServer
            }
        }
        #endif
    }

    // MARK: - Shipping Interface Selection

    private func interfaceCard(_ type: OnboardingInterfaceType) -> some View {
        let isSelected = selectedInterfaces.contains(type)

        return Button {
            if isSelected {
                selectedInterfaces.remove(type)
                if type == .tcp {
                    selectedTcpServer = nil
                }
            } else {
                selectedInterfaces.insert(type)
                if type == .tcp && selectedTcpServer == nil {
                    selectedTcpServer = TcpCommunityServer.defaultServer
                }
                if type == .ble {
                    onRequestBluetooth()
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Theme.accentColor : Theme.textDisabled)

                Image(systemName: type.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.accentColor : Theme.textSecondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)

                    Text(type.description)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    Text(type.subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textDisabled)
                }

                Spacer()
            }
            .padding(14)
            .background(isSelected ? Theme.accentColor.opacity(0.1) : Theme.backgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Theme.accentColor.opacity(0.5) : Theme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isReadOnly)
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
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
            .disabled(!isReadOnly && selectedInterfaces.isEmpty)
            .opacity(!isReadOnly && selectedInterfaces.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: - TCP Server

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
        .disabled(isReadOnly)
    }

    private var serverPickerSheet: some View {
        NavigationStack {
            List {
                Section("Recommended Relays") {
                    ForEach(TcpCommunityServer.servers.filter { $0.isBootstrap }) { server in
                        serverRow(server)
                    }
                }
                Section("Other Public Relays") {
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
