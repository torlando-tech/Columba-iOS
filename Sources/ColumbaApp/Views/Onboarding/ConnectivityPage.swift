#if COLUMBA_ONBOARDING_ENABLED
//
//  ConnectivityPage.swift
//  ColumbaApp
//
//  Onboarding page 2: Network interface selection with TCP server picker.
//

import SwiftUI
import CoreBluetooth
import Network

@available(iOS 17.0, macOS 14.0, *)
struct ConnectivityPage: View {
    @Binding var selectedInterfaces: Set<OnboardingInterfaceType>
    @Binding var selectedTcpServer: TcpCommunityServer?
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var showServerPicker = false
    @State private var bluetoothAuthorization: CBManagerAuthorization = CBCentralManager.authorization
    @State private var bluetoothProbe: BluetoothPermissionProbe?
    @State private var localNetworkProbe: LocalNetworkPermissionProbe?
    @State private var localNetworkPrompted = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.accentColor)
                        .padding(.bottom, 24)

                    Text("How will you connect?")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.bottom, 8)

                    Text("Select the networks you'd like to use:")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 24)

                    // Interface cards
                    VStack(spacing: 12) {
                        ForEach(OnboardingInterfaceType.allCases, id: \.self) { type in
                            interfaceCard(type)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                    // TCP server selection
                    if selectedInterfaces.contains(.tcp) {
                        tcpServerRow
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    }

                    // Bluetooth permission card
                    if selectedInterfaces.contains(.ble) {
                        bluetoothPermissionCard
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    }

                    Text("You can configure these later in Settings")
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
            if selectedInterfaces.contains(.auto) && !localNetworkPrompted {
                requestLocalNetworkPermission()
            }
        }
    }

    // MARK: - Interface Card

    private func interfaceCard(_ type: OnboardingInterfaceType) -> some View {
        let isSelected = selectedInterfaces.contains(type)

        return Button {
            if isSelected {
                selectedInterfaces.remove(type)
                if type == .tcp { selectedTcpServer = nil }
            } else {
                selectedInterfaces.insert(type)
                if type == .tcp && selectedTcpServer == nil {
                    selectedTcpServer = TcpCommunityServer.defaultServer
                }
                if type == .ble && CBCentralManager.authorization == .notDetermined {
                    requestBluetoothPermission()
                }
                if type == .auto && !localNetworkPrompted {
                    requestLocalNetworkPermission()
                }
            }
        } label: {
            HStack(spacing: 14) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Theme.accentColor : Theme.textDisabled)

                // Icon
                Image(systemName: type.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.accentColor : Theme.textSecondary)
                    .frame(width: 28)

                // Text
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
    }

    // MARK: - TCP Server Row

    private var tcpServerRow: some View {
        Button { showServerPicker = true } label: {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(Theme.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Server")
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

    // MARK: - Bluetooth Permission Card

    private var bluetoothPermissionCard: some View {
        let granted = bluetoothAuthorization == .allowedAlways

        return HStack(spacing: 14) {
            Image(systemName: "wave.3.right")
                .font(.system(size: 24))
                .foregroundStyle(granted ? Theme.success : Theme.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bluetooth Access")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(granted ? "Enabled" : "Required for BLE mesh networking")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.success)
            } else {
                Button {
                    requestBluetoothPermission()
                } label: {
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
                .stroke(granted ? Theme.success.opacity(0.5) : Theme.divider, lineWidth: 1)
        )
    }

    private func requestBluetoothPermission() {
        bluetoothProbe = BluetoothPermissionProbe { auth in
            bluetoothAuthorization = auth
        }
    }

    private func requestLocalNetworkPermission() {
        localNetworkPrompted = true
        localNetworkProbe = LocalNetworkPermissionProbe()
    }
}

/// Triggers the iOS Bluetooth permission dialog by initializing a CBCentralManager.
/// iOS shows the permission prompt on first CBCentralManager creation if authorization is .notDetermined.
private class BluetoothPermissionProbe: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let onAuthorizationChange: (CBManagerAuthorization) -> Void

    init(onAuthorizationChange: @escaping (CBManagerAuthorization) -> Void) {
        self.onAuthorizationChange = onAuthorizationChange
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onAuthorizationChange(CBCentralManager.authorization)
    }
}

/// Triggers the iOS local network permission dialog by browsing for a Bonjour service.
/// iOS shows the prompt on first local network access attempt.
private class LocalNetworkPermissionProbe {
    private var browser: NWBrowser?

    init() {
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_reticulum._tcp", domain: nil), using: params)
        browser?.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { return }
            // Brief browse is enough to trigger the prompt — cancel after 2s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.browser?.cancel()
                self?.browser = nil
            }
        }
        browser?.start(queue: .main)
    }
}
#endif
