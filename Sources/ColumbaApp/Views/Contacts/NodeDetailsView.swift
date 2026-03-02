//
//  NodeDetailsView.swift
//  Columba-iOS
//
//  Node details screen showing contact info cards and a Start Chat button.
//  Navigated to by tapping a contact card in ContactsView.
//

import SwiftUI
import LXMFSwift
import ReticulumSwift

/// Node details screen showing identity info and a Start Chat action.
///
/// Layout:
/// - Header: Large identicon, display name, online/expired status badge
/// - Action: "Start Chat" button (accent gradient, full width)
/// - Details cards: Destination hash, hop count, discovered/expires timestamps
@available(iOS 17.0, macOS 14.0, *)
struct NodeDetailsView: View {
    // MARK: - Properties

    /// Contact to display details for.
    let contact: Contact

    /// AppServices for path table lookup.
    let appServices: AppServices

    /// Called when "Start Chat" is tapped; receives the contact.
    var onStartChat: ((Contact) -> Void)?

    // MARK: - State

    @State private var expiresDate: Date?
    @State private var interfaceName: String?
    @State private var propagationInfo: PropagationNodeInfo?
    @State private var isCurrentRelay: Bool = false
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                if propagationInfo != nil {
                    setAsRelayButton
                } else {
                    startChatButton
                }
                detailsSection
                if propagationInfo != nil {
                    propagationDetailsSection
                }
            }
            .padding(16)
        }
        .background(Theme.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Node Details")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadPathDetails()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            // Large profile icon (MDI or identicon fallback)
            ProfileIcon(
                iconName: contact.iconName,
                foregroundColor: contact.iconFgColor,
                backgroundColor: contact.iconBgColor,
                fallbackHash: contact.identityHash,
                size: 80
            )

            // Display name
            Text(contact.resolvedDisplayName)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)

            // Status badge
            statusBadge
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(contact.isOnline ? Theme.success : Theme.error)
                .frame(width: 8, height: 8)

            Text(contact.isOnline ? "Online" : "Expired")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(contact.isOnline ? Theme.success : Theme.error)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill((contact.isOnline ? Theme.success : Theme.error).opacity(0.15))
        }
    }

    // MARK: - Start Chat Button

    private var startChatButton: some View {
        Button {
            onStartChat?(contact)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                Text("Start Chat")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                    .fill(Theme.accentGradient)
            }
        }
        .disabled(!contact.isOnline)
        .opacity(contact.isOnline ? 1.0 : 0.5)
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        VStack(spacing: 12) {
            detailRow(
                icon: "number",
                label: "Destination Hash",
                value: contact.identityHashHex,
                isMonospace: true,
                isCopyable: true
            )

            detailRow(
                icon: "point.3.connected.trianglepath.dotted",
                label: "Network Distance",
                value: contact.hopDescription
            )

            detailRow(
                icon: "antenna.radiowaves.left.and.right",
                label: "Interface",
                value: interfaceName ?? "Mesh Network"
            )

            detailRow(
                icon: "clock",
                label: "Discovered",
                value: formattedDate(contact.timestamp)
            )

            if let expires = expiresDate {
                detailRow(
                    icon: "clock.badge.xmark",
                    label: "Expires",
                    value: formattedDate(expires)
                )
            }
        }
    }

    private func detailRow(
        icon: String,
        label: String,
        value: String,
        isMonospace: Bool = false,
        isCopyable: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if isMonospace {
                    Text(value)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                } else {
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            Spacer()

            if isCopyable {
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = value
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard()
    }

    // MARK: - Set as Relay Button

    private var setAsRelayButton: some View {
        Button {
            if let propManager = appServices.propagationManager {
                if isCurrentRelay {
                    Task { await propManager.clearSelection() }
                    isCurrentRelay = false
                } else {
                    propManager.autoSelectEnabled = false
                    Task { await propManager.selectNode(hash: contact.identityHash) }
                    isCurrentRelay = true
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrentRelay ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                Text(isCurrentRelay ? "Current Relay" : "Set as My Relay")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                if isCurrentRelay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                        .fill(Theme.success)
                } else {
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                        .fill(Theme.accentGradient)
                }
            }
        }
    }

    // MARK: - Propagation Details

    private var propagationDetailsSection: some View {
        VStack(spacing: 12) {
            if let info = propagationInfo {
                detailRow(
                    icon: "tray.full",
                    label: "Per Transfer Limit",
                    value: "\(info.perTransferLimit) messages"
                )

                detailRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Per Sync Limit",
                    value: "\(info.perSyncLimit) messages"
                )

                if info.stampCost > 0 {
                    detailRow(
                        icon: "seal",
                        label: "Stamp Cost",
                        value: "\(info.stampCost)"
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func loadPathDetails() async {
        guard let pathTable = appServices.pathTable else { return }
        if let entry = await pathTable.lookup(destinationHash: contact.identityHash) {
            expiresDate = entry.expires
            // Resolve interface ID to human-readable name via transport
            if !entry.interfaceId.isEmpty {
                if let transport = appServices.transport {
                    interfaceName = await transport.getInterfaceName(for: entry.interfaceId)
                        ?? entry.interfaceId
                } else {
                    interfaceName = entry.interfaceId
                }
            }
            // Detect propagation node
            if let appData = entry.appData {
                propagationInfo = PropagationNodeInfo.parse(from: appData)
            }
        }
        // Check if this is the currently selected relay
        if let propManager = appServices.propagationManager {
            isCurrentRelay = propManager.selectedNodeHash == contact.identityHash
        }
    }
}
