//
//  BLEConnectionsView.swift
//  Columba-iOS
//
//  BLE Connections diagnostic screen showing all connected BLE mesh peers.
//  Port of Android Columba's BleConnectionStatusScreen.
//

import SwiftUI
import RNSAPI

// MARK: - BLE Connections View

/// Diagnostic screen showing all active BLE mesh peer connections.
///
/// Displays:
/// - Summary card with total/central/peripheral counts
/// - Per-peer connection cards with signal, MTU, duration, data stats
/// - Disconnect button per peer
/// - Empty/inactive states
@available(iOS 17.0, macOS 14.0, *)
struct BLEConnectionsView: View {
    let appServices: AppServices

    @State private var connections: [BLEConnectionInfo] = []
    @State private var isLoading = true
    @State private var refreshTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if isLoading {
                    loadingView
                } else if !appServices.isBLEActive {
                    bleInactiveView
                } else if connections.isEmpty {
                    emptyView
                } else {
                    summaryCard
                    ForEach(connections) { conn in
                        connectionCard(conn)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.backgroundPrimary)
        .navigationTitle("BLE Connections")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                }
            }
        }
        #endif
        .task {
            await refresh()
            isLoading = false
            startPeriodicRefresh()
        }
        // Event-driven: the NE pushes `networkStateChangedInApp` when a BLE peer
        // connects/disconnects, so the connection LIST updates immediately instead
        // of waiting for the poll. `onReceive` delivers on the main run loop and its
        // subscription is auto-cancelled when the view disappears (no observer leak).
        .onReceive(NotificationCenter.default.publisher(for: NotificationObserver.networkStateChangedInApp)) { _ in
            Task { await refresh() }
        }
        .onDisappear {
            // Tear down the live-metrics poll. The `onReceive` subscription above is
            // torn down automatically by SwiftUI when the view disappears.
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading connections...")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    // MARK: - BLE Inactive

    private var bleInactiveView: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 64))
                .foregroundStyle(Theme.textDisabled)

            Text("BLE Interface Not Active")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)

            Text("Enable the Bluetooth LE interface in Settings to see connections.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accentColor)

            Text("Bluetooth LE Active")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)

            Text("No active connections")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)

            Text("BLE peers will appear here when connected")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryItem(
                label: "Total",
                value: "\(connections.count)",
                icon: "antenna.radiowaves.left.and.right"
            )
            Spacer()
            summaryItem(
                label: "Central",
                value: "\(connections.filter { $0.isOutgoing }.count)",
                icon: "arrow.up.right.circle"
            )
            Spacer()
            summaryItem(
                label: "Peripheral",
                value: "\(connections.filter { !$0.isOutgoing }.count)",
                icon: "arrow.down.left.circle"
            )
        }
        .padding(16)
        .background(Theme.accentColor.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func summaryItem(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Theme.accentColor)
            Text(value)
                .font(.title.bold())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Connection Card

    private func connectionCard(_ conn: BLEConnectionInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: identity + type badge
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Peer \(conn.identityHash.prefix(8))")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(conn.identityHash)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                connectionTypeBadge(conn)
            }

            Divider().overlay(Theme.divider)

            // Signal strength row
            signalStrengthRow(conn)

            // Connection details
            detailRow(label: "MTU", value: "\(conn.mtu) bytes")
            detailRow(label: "Connected", value: formatDuration(conn.connectionDuration))
            detailRow(label: "Last Activity", value: formatTimestamp(conn.lastActivity))

            // Performance metrics
            if conn.bytesSent > 0 || conn.bytesReceived > 0 {
                Divider().overlay(Theme.divider)

                Text("Performance")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)

                detailRow(label: "Data Sent", value: formatBytes(conn.bytesSent))
                detailRow(label: "Data Received", value: formatBytes(conn.bytesReceived))
                detailRow(label: "Packets Sent", value: "\(conn.packetsSent)")
                detailRow(label: "Packets Received", value: "\(conn.packetsReceived)")
            }

            // Disconnect button
            Button {
                Task {
                    await appServices.disconnectBLEPeer(identityHex: conn.identityHash)
                    try? await Task.sleep(for: .milliseconds(300))
                    await refresh()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 14))
                    Text("Disconnect")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Theme.error)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.error.opacity(0.5), lineWidth: 1)
                )
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Connection Type Badge

    private func connectionTypeBadge(_ conn: BLEConnectionInfo) -> some View {
        Text(conn.connectionType)
            .font(.caption2.weight(.bold))
            .foregroundStyle(conn.isOutgoing ? Theme.accentColor : .purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((conn.isOutgoing ? Theme.accentColor : Color.purple).opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Signal Strength Row

    private func signalStrengthRow(_ conn: BLEConnectionInfo) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: signalIcon(conn.signalQuality))
                    .font(.system(size: 16))
                    .foregroundStyle(signalColor(conn.signalQuality))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Signal Strength")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    Text(conn.signalQuality.rawValue)
                        .font(.subheadline.bold())
                        .foregroundStyle(signalColor(conn.signalQuality))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(conn.rssi.map { "\($0) dBm" } ?? "—")
                    .font(.system(.subheadline, design: .monospaced).bold())
                    .foregroundStyle(Theme.textPrimary)
                // iOS exposes RSSI only for central-side connections
                // (CBPeripheral.readRSSI). When a peer connects to us as a
                // central — i.e., we hold a CBCentral for them via
                // CBPeripheralManager — there's no equivalent API. Show a
                // hint so the dash doesn't look like a missing-data bug.
                if conn.rssi == nil && conn.connectionType == "peripheral" {
                    Text("peripheral mode")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(Theme.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func signalIcon(_ quality: SignalQuality) -> String {
        switch quality {
        case .excellent: return "checkmark.circle.fill"
        case .good: return "checkmark.circle"
        case .fair: return "exclamationmark.triangle"
        case .poor: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func signalColor(_ quality: SignalQuality) -> Color {
        switch quality {
        case .excellent, .good: return Theme.success
        case .fair: return .orange
        case .poor: return Theme.error
        case .unknown: return Theme.textSecondary
        }
    }

    // MARK: - Detail Row

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Helpers

    private func refresh() async {
        connections = await appServices.getBLEConnectionInfos()
    }

    /// Slow while-visible poll for the live per-peer metrics (bytes / RSSI), which
    /// change continuously with no discrete event to push. The connection list itself
    /// is event-driven via `networkStateChangedInApp`; this only keeps the live
    /// counters ticking, so 4s is plenty. Started on appear, invalidated on disappear.
    private func startPeriodicRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            Task { @MainActor in
                await refresh()
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let minutes = s / 60
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m \(s % 60)s" }
        return "\(s)s"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.2f MB", Double(bytes) / 1_000_000.0)
        } else if bytes >= 1_000 {
            return String(format: "%.2f KB", Double(bytes) / 1_000.0)
        }
        return "\(bytes) B"
    }
}
