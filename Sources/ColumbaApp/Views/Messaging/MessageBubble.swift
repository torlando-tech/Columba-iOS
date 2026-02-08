//
//  MessageBubble.swift
//  Columba-iOS
//
//  Message bubble component with sent/received styling.
//  Sent messages use purple accent, received use dark glass material.
//

import SwiftUI
import LXMFSwift

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

    // MARK: - Theme

    /// Purple accent color matching Android Columba (Hex: #6750A4)
    private let accentColor = Color(red: 0.404, green: 0.314, blue: 0.643)

    /// Darker background for received messages
    private let receivedBackground = Color(white: 0.15)

    // MARK: - Body

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isFromMe {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                // Message content bubble
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(bubbleShape)

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
            accentColor.opacity(0.85)
        } else {
            receivedBackground
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        }
    }

    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            .foregroundStyle(accentColor)

        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Message Model

/// Message model for the messaging view.
public struct Message: Identifiable, Equatable {
    public let id: String
    public let content: String
    public let timestamp: Date
    public let isFromMe: Bool
    public var deliveryStatus: DeliveryStatus

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

    /// Create a new message.
    public init(
        id: String = UUID().uuidString,
        content: String,
        timestamp: Date = Date(),
        isFromMe: Bool,
        deliveryStatus: DeliveryStatus = .sent
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.deliveryStatus = deliveryStatus
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
    }

    /// Create from MessageRecord (lightweight, no LXMessage unpacking).
    ///
    /// Uses database columns directly, avoiding expensive MessagePack
    /// decode + SHA256 + Ed25519 verification per message.
    public init(from record: MessageRecord, localHash: Data) {
        self.id = record.messageId.map { String(format: "%02x", $0) }.joined()
        self.content = String(data: record.content, encoding: .utf8) ?? ""
        self.timestamp = Date(timeIntervalSince1970: record.timestamp)
        self.isFromMe = record.sourceHash == localHash

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
