//
//  MessageDetailView.swift
//  ColumbaApp
//
//  Message details screen showing delivery metadata.
//  Matches Android Columba's MessageDetailScreen with card-based layout.
//

import SwiftUI
import RNSAPI

/// Message detail screen showing delivery metadata in card-based layout.
///
/// Shows different cards based on message direction:
/// - **Sent**: Timestamp, Status, Delivery Method, Sending Interface (current
///   path), Error (if failed), Message ID.
/// - **Received**: Timestamp, Delivery Method, Receiving Interface, RSSI, SNR,
///   Message ID.
@available(iOS 17.0, macOS 14.0, *)
struct MessageDetailView: View {
    let message: Message

    /// Destination hash of the conversation peer. Used to resolve the current
    /// outgoing path's interface for outgoing messages.
    let destinationHash: Data?

    /// Path table for resolving the current next-hop interface to the
    /// destination. Optional so existing callers and previews can omit it.
    let pathTable: PathTable?

    @Environment(\.dismiss) private var dismiss

    /// Eagerly-constructed InterfaceRepository for resolving interface UUIDs
    /// to their configured friendly name and connection details. Init is
    /// synchronous (UserDefaults-backed), so constructing at view init time
    /// avoids a first-render flicker where the receiving-interface card would
    /// briefly fall through to the orphan branch.
    @State private var interfaceRepository: InterfaceRepository = InterfaceRepository()

    /// Interface UUID currently used to reach the destination, resolved
    /// asynchronously from the path table on appear. `nil` means either the
    /// lookup hasn't run yet, no path is known, or the path has expired.
    @State private var currentSendingInterfaceId: String?

    /// Convenience initializer that omits the path-table dependency. Used by
    /// previews and any caller that doesn't have a path table handy.
    init(message: Message, destinationHash: Data? = nil, pathTable: PathTable? = nil) {
        self.message = message
        self.destinationHash = destinationHash
        self.pathTable = pathTable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Message preview
                    messagePreview

                    Divider()
                        .background(Theme.divider)

                    // Info cards
                    if message.isFromMe {
                        sentMessageCards
                    } else {
                        receivedMessageCards
                    }
                }
                .padding(16)
            }
            .background(Theme.backgroundPrimary)
            .navigationTitle("Message Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accentColor)
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accentColor)
                }
                #endif
            }
            #if os(iOS)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
        .preferredColorScheme(.dark)
        // Only kick off the path lookup for outgoing messages. Incoming
        // messages don't need a sending-interface card, so don't waste a
        // PathTable lookup. SwiftUI runs .task on the main actor, so the
        // assignment in loadSendingInterface() is already main-actor isolated
        // — no MainActor.run needed.
        .task {
            guard message.isFromMe else { return }
            await loadSendingInterface()
        }
    }

    /// Resolve the current next-hop interface for the destination so the
    /// outgoing message details can show which configured interface is
    /// presently used to reach this peer.
    ///
    /// This is a *lookup at display time* — it reflects the path as it stands
    /// now, not necessarily the interface used at the original send time. The
    /// path table can change between send and view (new announces, expiry,
    /// network changes), so the displayed interface is best-effort. If no path
    /// is known the card is omitted entirely rather than guessing.
    @MainActor
    private func loadSendingInterface() async {
        guard message.isFromMe,
              let destinationHash,
              let pathTable
        else { return }

        // SwiftUI invokes .task on the main actor and this method is
        // @MainActor-isolated, so the @State assignment after the await is
        // already on the main actor — no MainActor.run wrapper needed.
        let entry = await pathTable.lookup(destinationHash: destinationHash)
        self.currentSendingInterfaceId = entry?.interfaceId
    }

    // MARK: - Message Preview

    private var messagePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: message.isFromMe ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(message.isFromMe ? Theme.accentColor : .green)
                Text(message.isFromMe ? "Sent Message" : "Received Message")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
            }

            if message.imageData != nil {
                Label("Image attached", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let attachments = message.attachments, !attachments.isEmpty {
                Label("\(attachments.count) file\(attachments.count == 1 ? "" : "s") attached", systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sent Message Cards

    @ViewBuilder
    private var sentMessageCards: some View {
        // Timestamp
        InfoCard(
            icon: "clock",
            iconColor: .blue,
            title: "Sent",
            content: formattedTimestamp,
            subtitle: relativeTime
        )

        // Status
        statusCard

        // Delivery method
        if let method = message.deliveryMethod {
            deliveryMethodCard(method)
        }

        // Sending interface (current next-hop for the destination).
        // Hidden when no path is known so we never show stale or made-up data.
        if let iface = currentSendingInterfaceId {
            interfaceCard(title: "Sending Interface", interfaceId: iface)
        }

        // Error details (if failed)
        if message.deliveryStatus == .failed {
            InfoCard(
                icon: "exclamationmark.triangle.fill",
                iconColor: .red,
                title: "Error",
                content: "No delivery confirmation",
                subtitle: "Common causes include an unavailable route, an offline recipient, or a delivery timeout. Check your interfaces and try again."
            )
        }

        // Message ID
        messageIdCard
    }

    // MARK: - Received Message Cards

    @ViewBuilder
    private var receivedMessageCards: some View {
        // Timestamp
        InfoCard(
            icon: "clock",
            iconColor: .blue,
            title: "Received",
            content: formattedTimestamp,
            subtitle: relativeTime
        )

        // Delivery method
        if let method = message.deliveryMethod {
            deliveryMethodCard(method)
        }

        // Receiving interface
        if let iface = message.receivedInterface {
            interfaceCard(title: "Receiving Interface", interfaceId: iface)
        }

        // RSSI
        if let rssi = message.rssi {
            rssiCard(rssi)
        }

        // SNR
        if let snr = message.snr {
            snrCard(snr)
        }

        // Message ID
        messageIdCard
    }

    // MARK: - Card Components

    private var statusCard: some View {
        let (icon, color, title, subtitle): (String, Color, String, String) = {
            switch message.deliveryStatus {
            case .delivered:
                return ("checkmark.circle.fill", .green, "Delivered",
                        "Message was successfully delivered to recipient")
            case .failed:
                return ("exclamationmark.circle.fill", .red, "Failed",
                        "Delivery failed — try resending")
            case .sending:
                return ("hourglass", .orange, "Sending",
                        "Message is being sent")
            case .sent:
                return ("paperplane.fill", .blue, "Sent",
                        "Message sent, awaiting delivery confirmation")
            case .read:
                return ("eye.fill", Theme.accentColor, "Read",
                        "Message has been read by recipient")
            }
        }()

        return InfoCard(
            icon: icon,
            iconColor: color,
            title: "Status",
            content: title,
            subtitle: subtitle
        )
    }

    private func deliveryMethodCard(_ method: String) -> some View {
        let (icon, title, subtitle): (String, String, String) = {
            switch method {
            case "opportunistic":
                return ("paperplane", "Opportunistic",
                        "Single encrypted packet, no link required")
            case "direct":
                return ("link", "Direct",
                        "Link-based delivery, supports large messages")
            case "propagated":
                return ("point.3.connected.trianglepath.dotted", "Propagated",
                        "Delivered via relay/propagation node")
            case "paper":
                return ("doc.text", "Paper",
                        "Transferred as a paper LXMF message")
            default:
                return ("questionmark.circle", method.capitalized, "")
            }
        }()

        return InfoCard(
            icon: icon,
            iconColor: .purple,
            title: "Delivery Method",
            content: title,
            subtitle: subtitle
        )
    }

    /// Card showing an interface (sending or receiving) by its UUID.
    ///
    /// Looks up the interface in the repository so we can show the user's
    /// configured friendly name (e.g. "beleth") and connection target
    /// (e.g. "example.com:4242") instead of raw UUID substrings. Used for both
    /// the receiving-interface card (the interface a packet arrived on) and
    /// the sending-interface card (the *current* next-hop interface for the
    /// destination, as-of-now — not necessarily the original transmit
    /// interface).
    private func interfaceCard(title: String, interfaceId: String) -> some View {
        let entity = resolveInterfaceEntity(for: interfaceId)
        let (icon, name, subtitle) = interfaceCardDisplay(for: entity, fallbackId: interfaceId)

        return InfoCard(
            icon: icon,
            iconColor: .cyan,
            title: title,
            content: name,
            subtitle: subtitle
        )
    }

    /// Resolve the parent `InterfaceEntity` for a (possibly peer-scoped) ID.
    ///
    /// BLE / AutoInterface / RNode / Multipeer peers are reported on
    /// packets as IDs of the form `{type}-{parentId}-{peerSuffix}` —
    /// e.g. `ble-ble0-628188b8`, `auto-auto0-fe80::...`,
    /// `rnode-rnode0-<peerHex>`. There's no shared key between the
    /// transport-layer parent ID (`ble0` etc., used by `InterfaceConfig`
    /// when the transport adds the interface) and the
    /// `InterfaceEntity` stored in `InterfaceRepository` (whose `id` is
    /// usually a `UUID()` from `OnboardingViewModel` /
    /// `InterfaceManagementViewModel`). Direct equality lookups miss
    /// for every peer-scoped packet and the "Network" orphan label gets
    /// rendered.
    ///
    /// Resolution order:
    /// 1. Direct lookup — covers TCP and any future IDs that happen to
    ///    match the entity ID exactly.
    /// 2. Parent-segment strip — covers the unlikely case where someone
    ///    wires the entity with the transport's parent string ("ble0").
    /// 3. Type-prefix match — the load-bearing case: any entity whose
    ///    `type` matches the leading `ble-` / `auto-` / `rnode-` /
    ///    `mpc-` prefix. With the standard "one BLE / one Auto / one
    ///    RNode" config, this returns the right entity unambiguously.
    private func resolveInterfaceEntity(for interfaceId: String) -> InterfaceEntity? {
        if let direct = interfaceRepository.getInterface(id: interfaceId) {
            return direct
        }

        let parts = interfaceId.split(separator: "-", maxSplits: 2)
        let prefix = parts.first.map(String.init)

        // 2. Parent-segment strip — works only for the legacy/explicit
        //    "id matches transport parent" wiring.
        if parts.count == 3,
           let p = prefix,
           ["ble", "auto", "rnode", "mpc"].contains(p),
           let parent = interfaceRepository.getInterface(id: String(parts[1])) {
            return parent
        }

        // 3. Type-prefix match — fall back to any entity whose `type`
        //    matches the prefix segment. Prefer enabled entities so a
        //    disabled-and-still-stored interface doesn't shadow the
        //    active one.
        guard let p = prefix, let typeForPrefix = typeForInterfacePrefix(p) else {
            return nil
        }
        let candidates = interfaceRepository.interfaces.filter { $0.type == typeForPrefix }
        return candidates.first(where: { $0.enabled }) ?? candidates.first
    }

    /// Map a packet-id prefix segment (`ble`, `auto`, `rnode`, `mpc`) to
    /// the corresponding `InterfaceType`. Returns nil for unrecognized
    /// prefixes (e.g. `tcp-` IDs hit the direct-lookup path before
    /// reaching here).
    private func typeForInterfacePrefix(_ prefix: String) -> InterfaceType? {
        switch prefix {
        case "ble":   return .ble
        case "auto":  return .autoInterface
        case "rnode": return .rnode
        case "mpc":   return .multipeer
        default:      return nil
        }
    }

    /// Resolve an InterfaceEntity to display values for the receiving-interface card.
    ///
    /// Returns `(icon, content, subtitle)`:
    /// - `content` is the user-configured friendly name (or "Network" for an orphan).
    /// - `subtitle` is the connection target (host:port, multicast group, BLE/USB, etc.)
    ///   or the raw UUID when the interface no longer exists in the repository.
    private func interfaceCardDisplay(
        for entity: InterfaceEntity?,
        fallbackId: String
    ) -> (icon: String, name: String, subtitle: String) {
        guard let entity else {
            // Orphan: the message arrived on an interface that has since been
            // deleted. Render gracefully with the raw UUID as the subtitle.
            return ("globe", "Network", fallbackId)
        }

        // Use the canonical icon from InterfaceType to keep this view aligned
        // with the rest of the app (interface list, settings, etc.).
        let icon = entity.type.icon

        // Peer-scoped IDs (`ble-ble0-628188b8`, `auto-auto0-fe80::...`,
        // `rnode-rnode0-<peerHex>`, `mpc-mpc0-<peer>`) carry the actual
        // peer identifier in the suffix. That's what the user wants on
        // the second line of the card — "via this specific peer", not
        // a generic protocol description. Fall back to the type-level
        // subtitle only for non-peer IDs (e.g. TCP, or a parent
        // interface seen directly).
        if let peerSubtitle = peerSubtitle(forInterfaceId: fallbackId) {
            return (icon, entity.name, peerSubtitle)
        }

        let subtitle: String
        switch entity.config {
        case .tcpClient(let cfg):
            subtitle = "\(cfg.targetHost):\(cfg.targetPort)"
        case .tcpServer(let cfg):
            subtitle = "Listening on \(cfg.listenIp):\(cfg.listenPort)"
        case .autoInterface(let cfg):
            if let groupId = cfg.groupId, !groupId.isEmpty {
                subtitle = "Auto Discovery / \(groupId)"
            } else {
                subtitle = "Auto Discovery (\(cfg.discoveryScope))"
            }
        case .ble:
            subtitle = "Bluetooth LE Mesh"
        case .rnode(let cfg):
            let device = cfg.deviceName.isEmpty ? "RNode" : cfg.deviceName
            subtitle = "RNode LoRa / \(device)"
        case .multipeer(let cfg):
            subtitle = "Nearby / \(cfg.serviceType)"
        }

        return (icon, entity.name, subtitle)
    }

    /// Format the peer-scoped suffix of an interfaceId for display on
    /// the message-details card subtitle. Returns nil if the id isn't
    /// in the peer-scoped `{type}-{parent}-{suffix}` form, which lets
    /// the caller fall through to the entity's protocol-level subtitle.
    ///
    /// For BLE the suffix is the first 8 hex chars of the peer's
    /// identity; for AutoInterface it's the IPv6 link-local; for
    /// RNode / Multipeer it's the peer-specific identifier the
    /// transport assigned. Either way, surfacing it on the subtitle
    /// answers the user's "which specific peer was this routed
    /// through?" question.
    private func peerSubtitle(forInterfaceId interfaceId: String) -> String? {
        let parts = interfaceId.split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              ["ble", "auto", "rnode", "mpc"].contains(String(parts[0])) else {
            return nil
        }
        return "Peer \(parts[2])"
    }

    private func rssiCard(_ rssi: Double) -> some View {
        let intRssi = Int(rssi)
        let (quality, color): (String, Color) = {
            switch intRssi {
            case -50...0:
                return ("Excellent signal", .green)
            case -70 ..< -50:
                return ("Good signal", .green)
            case -85 ..< -70:
                return ("Fair signal", .orange)
            case -100 ..< -85:
                return ("Weak signal", .red)
            default:
                return ("Very weak signal", .red)
            }
        }()

        return InfoCard(
            icon: "antenna.radiowaves.left.and.right",
            iconColor: color,
            title: "Signal Strength (RSSI)",
            content: "\(intRssi) dBm",
            subtitle: quality
        )
    }

    private func snrCard(_ snr: Double) -> some View {
        let (quality, color): (String, Color) = {
            switch snr {
            case 10...:
                return ("Excellent quality", .green)
            case 5..<10:
                return ("Good quality", .green)
            case 0..<5:
                return ("Fair quality", .orange)
            default:
                return ("Poor quality", .red)
            }
        }()

        return InfoCard(
            icon: "waveform",
            iconColor: color,
            title: "Signal Quality (SNR)",
            content: String(format: "%.1f dB", snr),
            subtitle: quality
        )
    }

    private var messageIdCard: some View {
        InfoCard(
            icon: "number",
            iconColor: .gray,
            title: "Message Hash",
            content: message.id,
            subtitle: nil,
            monospaced: true
        )
    }

    // MARK: - Formatting

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: message.timestamp)
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: message.timestamp, relativeTo: Date())
    }
}

// MARK: - Info Card

/// Reusable card component for message detail info items.
private struct InfoCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let content: String
    var subtitle: String?
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon circle
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(iconColor.opacity(0.2))
                .clipShape(Circle())

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if monospaced {
                    Text(content)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text(content)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(Theme.backgroundTertiary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
