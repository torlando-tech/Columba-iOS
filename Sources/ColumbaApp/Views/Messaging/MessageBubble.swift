//
//  MessageBubble.swift
//  Columba-iOS
//
//  Message bubble component with sent/received styling.
//  Sent messages use purple accent, received use dark glass material.
//

import SwiftUI
import LXMFSwift
#if canImport(UIKit)
import UIKit
#endif

/// Individual message bubble view.
///
/// Layout:
/// - Sent messages: right-aligned with purple/accent background
/// - Received messages: left-aligned with darker glass material
/// - Timestamp below bubble
/// - Delivery status checkmarks for sent messages
struct MessageBubble: View {
    // MARK: - Properties

    let message: Message

    /// Callback for retry action (failed messages only).
    var onRetry: (() -> Void)?
    /// Callback for showing message details.
    var onShowDetails: (() -> Void)?
    /// Callback for deleting this message.
    var onDelete: (() -> Void)?

    // MARK: - Theme (delegates to Theme/ThemeManager)

    // MARK: - Body

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isFromMe {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                // Message content bubble
                VStack(alignment: .leading, spacing: 6) {
                    // Inline image
                    if let imageData = message.imageData,
                       let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 250)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    // Text content (show if non-empty)
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.body)
                            .foregroundStyle(.white)
                    }

                    // File attachment chips
                    if let attachments = message.attachments, !attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                                fileChip(name: attachment.name, size: attachment.data.count)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(bubbleShape)
                .contextMenu {
                    if message.deliveryStatus == .failed, let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }

                    if !message.content.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

                    if let onShowDetails {
                        Button {
                            onShowDetails()
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                    }

                    if let onDelete {
                        Divider()
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                // Timestamp and status row
                HStack(spacing: 4) {
                    Text(message.formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.isFromMe {
                        deliveryStatusIcon
                    }
                }
            }

            if !message.isFromMe {
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - Bubble Styling

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.isFromMe {
            Theme.sentBubbleColor.opacity(0.85)
        } else {
            Theme.receivedBubbleColor
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        }
    }

    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    // MARK: - File Chip

    private func fileChip(name: String, size: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Text(name)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(Self.formatFileSize(size))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }

    private static func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Delivery Status

    @ViewBuilder
    private var deliveryStatusIcon: some View {
        switch message.deliveryStatus {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .delivered:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

        case .read:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.caption2)
            .foregroundStyle(Theme.accentColor)

        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Message Model

/// Message model for the messaging view.
/// File attachment tuple for display.
public struct FileAttachment: Equatable {
    public let name: String
    public let data: Data
}

public struct Message: Identifiable, Equatable {
    public let id: String
    public var content: String
    public let timestamp: Date
    public let isFromMe: Bool
    public var deliveryStatus: DeliveryStatus
    public var imageData: Data?
    public var imageFormat: String?
    public var attachments: [FileAttachment]?

    // Metadata for message details
    public var deliveryMethod: String?
    public var rssi: Double?
    public var snr: Double?
    public var messageHash: Data?
    public var receivedInterface: String?

    /// Cached formatter for relative time strings.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Formatted time string (e.g., "5 min ago", "Just now")
    public var formattedTime: String {
        Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date())
    }

    /// True if message has no visible content (telemetry-only messages).
    public var isEmpty: Bool {
        content.isEmpty && imageData == nil && (attachments == nil || attachments!.isEmpty)
    }

    /// Create a new message.
    public init(
        id: String = UUID().uuidString,
        content: String,
        timestamp: Date = Date(),
        isFromMe: Bool,
        deliveryStatus: DeliveryStatus = .sent,
        imageData: Data? = nil,
        imageFormat: String? = nil,
        attachments: [FileAttachment]? = nil
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.deliveryStatus = deliveryStatus
        self.imageData = imageData
        self.imageFormat = imageFormat
        self.attachments = attachments
    }

    /// Create from LXMessage.
    public init(from lxMessage: LXMessage, localHash: Data) {
        self.id = lxMessage.hash.map { String(format: "%02x", $0) }.joined()
        self.content = String(data: lxMessage.content, encoding: .utf8) ?? ""
        self.timestamp = Date(timeIntervalSince1970: lxMessage.timestamp)
        self.isFromMe = lxMessage.sourceHash == localHash

        // Map LXMessage state to DeliveryStatus
        switch lxMessage.state {
        case .sending:
            self.deliveryStatus = .sending
        case .sent:
            self.deliveryStatus = .sent
        case .delivered:
            self.deliveryStatus = .delivered
        case .failed:
            self.deliveryStatus = .failed
        default:
            self.deliveryStatus = .sent
        }

        // Extract image field (0x06): [format_string, binary_data]
        if let imageField = lxMessage.fields?[LXMessage.FIELD_IMAGE] as? [Any],
           imageField.count >= 2,
           let format = imageField[0] as? String,
           let data = imageField[1] as? Data {
            self.imageData = data
            self.imageFormat = format
        }

        // Extract file attachments field (0x05): [[filename, data], ...]
        if let filesField = lxMessage.fields?[LXMessage.FIELD_FILE_ATTACHMENTS] as? [Any] {
            var atts: [FileAttachment] = []
            for item in filesField {
                if let pair = item as? [Any],
                   pair.count >= 2,
                   let name = pair[0] as? String,
                   let data = pair[1] as? Data {
                    atts.append(FileAttachment(name: name, data: data))
                }
            }
            if !atts.isEmpty { self.attachments = atts }
        }
    }

    /// Create from MessageRecord.
    ///
    /// Uses database columns directly for basic fields. For messages with
    /// LXMF fields (images, attachments), unpacks from the stored wire format.
    public init(from record: MessageRecord, localHash: Data) {
        self.id = record.messageId.map { String(format: "%02x", $0) }.joined()
        self.content = String(data: record.content, encoding: .utf8) ?? ""
        self.timestamp = Date(timeIntervalSince1970: record.timestamp)
        self.isFromMe = record.sourceHash == localHash
        self.messageHash = record.messageId

        // Map raw state value to DeliveryStatus
        switch record.state {
        case LXMessageState.sending.rawValue:
            self.deliveryStatus = .sending
        case LXMessageState.sent.rawValue:
            self.deliveryStatus = .sent
        case LXMessageState.delivered.rawValue:
            self.deliveryStatus = .delivered
        case LXMessageState.failed.rawValue:
            self.deliveryStatus = .failed
        default:
            self.deliveryStatus = .sent
        }

        // Map delivery method
        switch record.method {
        case LXDeliveryMethod.opportunistic.rawValue:
            self.deliveryMethod = "opportunistic"
        case LXDeliveryMethod.direct.rawValue:
            self.deliveryMethod = "direct"
        case LXDeliveryMethod.propagated.rawValue:
            self.deliveryMethod = "propagated"
        default:
            self.deliveryMethod = nil
        }

        // Signal quality
        self.rssi = record.rssi
        self.snr = record.snr

        // Extract fields from packed wire format if available
        if let lxMessage = try? LXMessage.unpackFromBytes(record.packedLxmf) {
            // Re-extract content from unpacked message if DB column was empty
            if self.content.isEmpty {
                let unpacked = String(data: lxMessage.content, encoding: .utf8) ?? ""
                if !unpacked.isEmpty {
                    self.content = unpacked
                }
            }
            // Extract image field (0x06)
            if let imageField = lxMessage.fields?[LXMessage.FIELD_IMAGE] as? [Any],
               imageField.count >= 2,
               let format = imageField[0] as? String,
               let data = imageField[1] as? Data {
                self.imageData = data
                self.imageFormat = format
            } else if lxMessage.fields?[LXMessage.FIELD_IMAGE] != nil {
                // Image field exists but failed extraction — log for diagnosis
                let rawField = lxMessage.fields![LXMessage.FIELD_IMAGE]!
                print("[IMAGE_DEBUG] Field 0x06 present but extraction failed: type=\(type(of: rawField)), value=\(String(describing: rawField).prefix(200))")
            }
            // Extract file attachments field (0x05)
            if let filesField = lxMessage.fields?[LXMessage.FIELD_FILE_ATTACHMENTS] as? [Any] {
                var atts: [FileAttachment] = []
                for item in filesField {
                    if let pair = item as? [Any],
                       pair.count >= 2,
                       let name = pair[0] as? String,
                       let data = pair[1] as? Data {
                        atts.append(FileAttachment(name: name, data: data))
                    }
                }
                if !atts.isEmpty { self.attachments = atts }
            }
        }
    }
}

/// Message delivery status.
public enum DeliveryStatus: Equatable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

// MARK: - Preview

#Preview("Sent Message") {
    VStack(spacing: 16) {
        MessageBubble(message: Message(
            content: "Hi there!",
            timestamp: Date(),
            isFromMe: true,
            deliveryStatus: .delivered
        ))

        MessageBubble(message: Message(
            content: "Hello!",
            timestamp: Date().addingTimeInterval(-300),
            isFromMe: false
        ))
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
