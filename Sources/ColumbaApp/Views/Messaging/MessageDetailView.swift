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
@available(iOS 17.0, *)
struct MessageDetailView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Message preview
                    messagePreview

                    Divider()
                        .background(Color.white.opacity(0.1))

                    // Info cards
                    if message.isFromMe {
                        sentMessageCards
                    } else {
                        receivedMessageCards
                    }
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("Message Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accentColor)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
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
        let id = interfaceId.lowercased()
        let (icon, name): (String, String) = {
            if id.contains("ble") {
                return ("wave.3.right", "Bluetooth LE")
            } else if id.contains("rnode") {
                return ("antenna.radiowaves.left.and.right", "RNode")
            } else if id.contains("auto") {
                return ("wifi", "AutoInterface (WiFi/LAN)")
            } else if id.contains("tcp") {
                return ("globe", "TCP")
            } else {
                return ("globe", "Network")
            }
        }()

        return InfoCard(
            icon: icon,
            iconColor: .cyan,
            title: "Receiving Interface",
            content: name,
            subtitle: interfaceId
        )
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
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
