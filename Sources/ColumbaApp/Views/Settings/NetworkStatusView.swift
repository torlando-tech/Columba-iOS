//
//  NetworkStatusView.swift
//  ColumbaApp
//
//  Network Status screen showing all active interfaces and their states.
//  Dynamically populated list includes AutoInterfacePeers discovered via LAN.
//

import SwiftUI
import RNSAPI

// MARK: - Network Status View

/// Network Status screen showing all registered interfaces with live status.
///
/// Layout:
/// - Status card: overall network status with color indicator
/// - Interfaces card: dynamically populated list of all active interfaces
///   including TCPClient, AutoInterface parent, and AutoInterfacePeers
@available(iOS 17.0, macOS 14.0, *)
struct NetworkStatusView: View {

    // MARK: - State

    @State private var viewModel: NetworkStatusViewModel
    @State private var selectedInterface: InterfaceInfo?
    private let appServices: AppServices

    // MARK: - Init

    init(appServices: AppServices) {
        self.appServices = appServices
        _viewModel = State(initialValue: NetworkStatusViewModel(appServices: appServices))
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                interfacesCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle("Network Status")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .sheet(item: $selectedInterface) { info in
            interfaceDetailSheet(info)
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accentColor)

                Text("Status")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()
            }

            Divider()
                .overlay(Theme.divider)

            // Initialization status
            HStack(spacing: 10) {
                Circle()
                    .fill(viewModel.isInitialized ? Theme.success : Theme.error)
                    .frame(width: 10, height: 10)

                Text(viewModel.isInitialized ? "Reticulum Initialized" : "Not Initialized")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }

            // Network status
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(viewModel.networkStatus)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }

            #if ENABLE_NETWORK_EXTENSION
            // Background transport status
            if let tunnel = appServices.tunnelManager {
                HStack(spacing: 10) {
                    Circle()
                        .fill(tunnel.isRunning ? Theme.success : Theme.textSecondary)
                        .frame(width: 10, height: 10)

                    Text(tunnel.isRunning ? "Background Transport Active" : "Background Transport Off")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            #endif
        }
        .padding(16)
        .glassCard()
    }

    private var statusColor: Color {
        if !viewModel.isInitialized { return Theme.error }
        if viewModel.activeCount == viewModel.interfaces.count && viewModel.activeCount > 0 {
            return Theme.success
        } else if viewModel.activeCount > 0 {
            return Theme.warning
        }
        return Theme.error
    }

    // MARK: - Interfaces Card

    private var interfacesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accentColor)

                Text("Network Interfaces")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Text("\(viewModel.interfaces.count)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.backgroundTertiary)
                    .clipShape(Capsule())
            }

            Divider()
                .overlay(Theme.divider)

            if viewModel.interfaces.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(Theme.textDisabled)
                        Text("No interfaces active")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ForEach(viewModel.interfaces) { info in
                    Button {
                        selectedInterface = info
                    } label: {
                        interfaceRow(info)
                    }
                    .buttonStyle(.plain)
                    if info.id != viewModel.interfaces.last?.id {
                        Divider()
                            .overlay(Theme.divider)
                    }
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Interface Row

    private func interfaceRow(_ info: InterfaceInfo) -> some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: iconForType(info.type))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accentColor)
                .frame(width: 28, height: 28)
                .background(Theme.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Name and type
            VStack(alignment: .leading, spacing: 2) {
                Text(info.type)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)

                if let addr = info.peerAddress {
                    Text(addr)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(info.name)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            // State description
            Text(stateLabel(info.state))
                .font(.caption2)
                .foregroundStyle(info.online ? Theme.success : Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((info.online ? Theme.success : Theme.textSecondary).opacity(0.12))
                .clipShape(Capsule())

            // Status icon
            Image(systemName: statusIcon(info))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusIconColor(info))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Interface Detail Sheet

    private func interfaceDetailSheet(_ info: InterfaceInfo) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status header
                    HStack(spacing: 12) {
                        Image(systemName: iconForType(info.type))
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Theme.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Theme.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.type)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(stateLabel(info.state))
                                .font(.subheadline)
                                .foregroundStyle(info.online ? Theme.success : Theme.error)
                        }

                        Spacer()

                        Image(systemName: statusIcon(info))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(statusIconColor(info))
                    }
                    .padding(16)
                    .glassCard()

                    // Details
                    VStack(alignment: .leading, spacing: 12) {
                        detailRow(label: "Name", value: info.name)
                        detailRow(label: "Type", value: info.type)
                        detailRow(label: "ID", value: info.id)
                        if let addr = info.peerAddress {
                            detailRow(label: "Peer Address", value: addr)
                        }
                    }
                    .padding(16)
                    .glassCard()

                    // Error section
                    if let error = info.lastErrorDescription {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.error)
                                Text("Connection Error")
                                    .font(.headline)
                                    .foregroundStyle(Theme.error)
                            }

                            Text(error)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                        .padding(16)
                        .glassCard()
                    } else if !info.online {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(Theme.warning)
                                Text("Interface Offline")
                                    .font(.headline)
                                    .foregroundStyle(Theme.warning)
                            }

                            Text("This interface is not currently connected. Check your network settings and ensure the destination is reachable.")
                                .font(.callout)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(16)
                        .glassCard()
                    }
                }
                .padding(16)
            }
            .background(Theme.backgroundPrimary)
            .navigationTitle("Interface Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { selectedInterface = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    private func iconForType(_ type: String) -> String {
        switch type {
        case "TCPClient": return "network"
        case "AutoInterface": return "wifi"
        case "AutoInterfacePeer": return "person.line.dotted.person"
        case "UDP": return "bolt.horizontal"
        case "I2P": return "lock.shield"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private func statusIcon(_ info: InterfaceInfo) -> String {
        switch info.state {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "arrow.clockwise.circle"
        case .reconnecting:
            return "exclamationmark.triangle.fill"
        case .disconnected, .notConnected:
            return "xmark.circle"
        case .connectionFailed, .sendFailed, .invalidConfig:
            return "exclamationmark.octagon.fill"
        }
    }

    private func statusIconColor(_ info: InterfaceInfo) -> Color {
        switch info.state {
        case .connected:
            return Theme.success
        case .connecting:
            return Theme.warning
        case .reconnecting:
            return Theme.warning
        case .disconnected, .notConnected:
            return Theme.error
        case .connectionFailed, .sendFailed, .invalidConfig:
            return Theme.error
        }
    }

    private func stateLabel(_ state: InterfaceState) -> String {
        switch state {
        case .connected: return "Online"
        case .connecting: return "Connecting"
        case .reconnecting(let attempt): return "Retry #\(attempt)"
        case .disconnected: return "Offline"
        case .notConnected: return "Not connected"
        case .connectionFailed(let why): return "Failed: \(why)"
        case .sendFailed(let why): return "Send failed: \(why)"
        case .invalidConfig(let why): return "Invalid: \(why)"
        }
    }
}
