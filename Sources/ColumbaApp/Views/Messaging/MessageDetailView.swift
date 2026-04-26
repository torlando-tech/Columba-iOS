//
//  MessageDetailView.swift
//  ColumbaApp
//
//  Message details screen showing delivery metadata.
//  Matches Android Columba's MessageDetailScreen with card-based layout.
//

import SwiftUI

/// Message detail screen showing delivery metadata in card-based layout.
///
/// Shows different cards based on message direction:
/// - **Sent**: Timestamp, Status, Delivery Method, Error (if failed)
/// - **Received**: Timestamp, Delivery Method, RSSI, SNR
@available(iOS 17.0, macOS 14.0, *)
struct MessageDetailView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss

    /// Lazily-loaded InterfaceRepository for resolving interface UUIDs to
    /// their configured friendly name and connection details. Loaded on first
    /// view appearance (UserDefaults-backed; cheap to construct).
    @State private var interfaceRepository: InterfaceRepository?

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
        .onAppear {
            // Lazily load the interface repo so receivedInterfaceCard can
            // resolve UUIDs to the user's configured names. The repo reads
            // from UserDefaults in init, which is cheap.
            if interfaceRepository == nil {
                interfaceRepository = InterfaceRepository()
            }
        }
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

        // Error details (if failed)
        if message.deliveryStatus == .failed {
            InfoCard(
                icon: "exclamationmark.triangle.fill",
                iconColor: .red,
                title: "Error",
                content: "Delivery failed",
                subtitle: "The message could not be delivered to the recipient"
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
            receivedInterfaceCard(iface)
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

    private func receivedInterfaceCard(_ interfaceId: String) -> some View {
        // Look up the interface by its UUID in the repository so we can show
        // the user's configured friendly name (e.g. "beleth") and connection
        // target (e.g. "example.com:4242") instead of raw UUID substrings.
        let entity = interfaceRepository?.getInterface(id: interfaceId)
        let (icon, name, subtitle) = interfaceCardDisplay(for: entity, fallbackId: interfaceId)

        return InfoCard(
            icon: icon,
            iconColor: .cyan,
            title: "Receiving Interface",
            content: name,
            subtitle: subtitle
        )
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

        let icon: String
        let subtitle: String
        switch entity.config {
        case .tcpClient(let cfg):
            icon = "globe"
            subtitle = "\(cfg.targetHost):\(cfg.targetPort)"
        case .tcpServer(let cfg):
            icon = "globe"
            subtitle = "Listening on \(cfg.listenIp):\(cfg.listenPort)"
        case .autoInterface(let cfg):
            icon = "wifi"
            if let groupId = cfg.groupId, !groupId.isEmpty {
                subtitle = "Auto Discovery / \(groupId)"
            } else {
                subtitle = "Auto Discovery (\(cfg.discoveryScope))"
            }
        case .ble:
            icon = "wave.3.right"
            subtitle = "Bluetooth LE Mesh"
        case .rnode(let cfg):
            icon = "antenna.radiowaves.left.and.right"
            let device = cfg.deviceName.isEmpty ? "RNode" : cfg.deviceName
            subtitle = "RNode LoRa / \(device)"
        case .multipeer(let cfg):
            icon = "apple.logo"
            subtitle = "Nearby / \(cfg.serviceType)"
        }

        return (icon, entity.name, subtitle)
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
