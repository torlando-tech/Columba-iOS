//
//  MessageBubble.swift
//  Columba-iOS
//
//  Message bubble component with sent/received styling.
//  Sent messages use purple accent, received use dark glass material.
//

import SwiftUI
import RNSAPI
import os.log
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "network.columba.Columba", category: "MessageBubble")

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
    var messageTextScale: Double = SettingsRepository.MessageTextScale.defaultValue
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 17

    /// Callback for tapping a reaction chip to toggle own reaction.
    var onToggleReaction: ((String) -> Void)?
    /// Callback when user taps the reply preview to scroll to original.
    var onTapReplyPreview: ((String) -> Void)?
    /// Callback for long-press to enter reaction mode.
    var onLongPress: (() -> Void)?
    /// Callback for validated in-app message links such as NomadNet pages.
    var onOpenLink: ((MessageLinkTarget) -> Void)?
    /// Callback for opening the message's inline image attachment.
    var onOpenImage: (() -> Void)?
    /// Callback for opening a file attachment by its stable message-local index.
    var onOpenFileAttachment: ((Int) -> Void)?

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
                    // Reply preview
                    if let replyPreview = message.replyToPreview {
                        Button {
                            if let replyId = message.replyToId {
                                onTapReplyPreview?(replyId)
                            }
                        } label: {
                            Text(replyPreview)
                                .font(.caption)
                                .foregroundStyle(message.isFromMe ? .white.opacity(0.7) : .secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Theme.accentColor)
                                        .frame(width: 2)
                                }
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }

                    // Inline image
                    if let imageData = message.imageData,
                       let uiImage = UIImage(data: imageData) {
                        Button {
                            onOpenImage?()
                        } label: {
                            Image(platformImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 250)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        // Stable handle for the Tests/interop/ harness:
                        // `assertVisible: { id: "bubble_image" }` confirms an
                        // inbound image actually rendered (vs the bubble
                        // existing without an image).
                        .accessibilityIdentifier("bubble_image")
                        .accessibilityLabel(String(localized: "Image attachment"))
                        .accessibilityHint(String(localized: "Opens attachment preview"))
                    }

                    // Text content (show if non-empty)
                    if !message.content.isEmpty {
                        MessageBody(
                            content: message.content,
                            renderer: message.renderer,
                            color: message.isFromMe ? .white : Theme.textPrimary,
                            isOutgoing: message.isFromMe,
                            fontSize: bodyFontSize * CGFloat(messageTextScale),
                            onOpenLink: onOpenLink
                        )
                            // The text is already findable via Maestro's
                            // `text:` matcher; the identifier just lets the
                            // harness disambiguate the bubble's text from
                            // chrome that happens to contain the same string.
                            .accessibilityIdentifier("bubble_text")
                    }

                    // File attachment chips
                    if let attachments = message.attachments, !attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                                Button {
                                    onOpenFileAttachment?(index)
                                } label: {
                                    fileChip(name: attachment.name, size: attachment.data.count)
                                        .accessibilityIdentifier("bubble_file_chip")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("bubble_file_chip_\(index)")
                                .accessibilityLabel(
                                    String(localized: "File attachment: \(attachment.name)")
                                )
                                .accessibilityHint(String(localized: "Opens attachment preview"))
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(bubbleShape)
                .contentShape(bubbleShape)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                            onLongPress?()
                        }
                )

                // Reaction chips (below bubble)
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.reactions, id: \.emoji) { reaction in
                            Button {
                                onToggleReaction?(reaction.emoji)
                            } label: {
                                HStack(spacing: 2) {
                                    Text(reaction.emoji)
                                        .font(.caption2)
                                    if reaction.count > 1 {
                                        Text("\(reaction.count)")
                                            .font(.caption2)
                                            .foregroundStyle(reaction.includesMe ? Theme.accentColor : .secondary)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    reaction.includesMe
                                        ? Theme.accentColor.opacity(0.2)
                                        : Color.gray.opacity(0.15)
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
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
                        .stroke(Theme.divider, lineWidth: 0.5)
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
        .accessibilityElement(children: .combine)
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

/// Aggregated reaction for display on a message bubble.
public struct ReactionDisplay: Equatable {
    public let emoji: String
    public let count: Int
    public let includesMe: Bool
}

public struct Message: Identifiable, Equatable {
    public let id: String
    public var content: String
    public let timestamp: Date
    public let isFromMe: Bool
    public var deliveryStatus: DeliveryStatus
    public var renderer: MessageRenderer
    public var imageData: Data?
    public var imageFormat: String?
    public var attachments: [FileAttachment]?

    // Metadata for message details
    public var deliveryMethod: String?
    public var rssi: Double?
    public var snr: Double?
    public var messageHash: Data?
    /// Durable database key. This differs from `messageHash` when a staged
    /// retry was accepted on the wire but canonical replacement failed.
    public var storageHash: Data?
    /// Whether reply/reaction protocols may safely target `messageHash`.
    public var isTargetSafe: Bool = false
    public var receivedInterface: String?

    // Reply & reactions
    public var replyToId: String?
    public var replyToPreview: String?
    public var reactions: [ReactionDisplay]

    /// Cached formatter for relative time strings.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Formatted time string (e.g., "5 min ago", "Just now")
    public var formattedTime: String {
        // Clamp future-dated timestamps to now: a peer (or our own past clock)
        // can stamp a wire ts ahead of local time, and we must never render
        // "in 5 min" on a message that has already arrived.
        let now = Date()
        let display = min(timestamp, now)
        return Self.relativeFormatter.localizedString(for: display, relativeTo: now)
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
        renderer: MessageRenderer = .plain,
        imageData: Data? = nil,
        imageFormat: String? = nil,
        attachments: [FileAttachment]? = nil,
        replyToId: String? = nil,
        replyToPreview: String? = nil,
        reactions: [ReactionDisplay] = [],
        storageHash: Data? = nil,
        isTargetSafe: Bool = false
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.deliveryStatus = deliveryStatus
        self.renderer = renderer
        self.imageData = imageData
        self.imageFormat = imageFormat
        self.attachments = attachments
        self.replyToId = replyToId
        self.replyToPreview = replyToPreview
        self.reactions = reactions
        self.storageHash = storageHash
        self.isTargetSafe = isTargetSafe
    }

    /// Create from LXMessage.
    public init(from lxMessage: LXMessage, localHash: Data) {
        self.id = lxMessage.hash.map { String(format: "%02x", $0) }.joined()
        // Only canonical 32-byte LXMF hashes may be used as reaction/reply
        // targets. A 33-byte ID is the local persistence namespace used when an
        // abnormal delivered message arrives without a recoverable wire hash.
        self.messageHash = lxMessage.hash.count == 32 ? lxMessage.hash : nil
        self.storageHash = lxMessage.hash
        self.isTargetSafe = lxMessage.hash.count == 32
        self.content = String(data: lxMessage.content, encoding: .utf8) ?? ""
        self.timestamp = Date(timeIntervalSince1970: lxMessage.timestamp)
        self.isFromMe = lxMessage.sourceHash == localHash
        self.renderer = MessageRenderer(fields: lxMessage.fields)

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

        // Extract reply_to from FIELD_APP_DATA (0x10)
        if let appData = lxMessage.fields?[LXMessage.FIELD_APP_DATA] as? [String: Any],
           let replyTo = appData["reply_to"] as? String {
            self.replyToId = replyTo
        }
        self.reactions = []  // Accumulated separately
    }

    /// Create from MessageRecord.
    ///
    /// Uses database columns directly for basic fields. For messages with
    /// LXMF fields (images, attachments), unpacks from the stored wire format.
    public init(from record: MessageRecord, localHash: Data) {
        self.id = record.messageId.map { String(format: "%02x", $0) }.joined()
        self.content = String(data: record.content, encoding: .utf8) ?? ""
        self.timestamp = Date(timeIntervalSince1970: record.timestamp)
        // Use the persisted direction (.outbound for messages we sent), set at
        // save time from `LXMessage.incoming`. The previous `record.sourceHash
        // == localHash` check was always false on reload: sourceHash is the
        // sender's *identity* hash, while localHash is the local *lxmf.delivery
        // destination* hash — two different values — so every reloaded sent
        // message rendered as received. (localHash is still used below for
        // reaction `includesMe`.)
        self.isFromMe = record.direction == .outbound
        self.renderer = .plain
        self.storageHash = record.messageId
        if let wireHash = MessageRepository.canonicalHashFromUncertainRetryMarker(record.receivingInterface) {
            self.messageHash = wireHash
            self.isTargetSafe = false
        } else {
            self.messageHash = record.messageId.count == 32 ? record.messageId : nil
            self.isTargetSafe = record.messageId.count == 32
                && !MessageRepository.isUncertainRetryMarker(record.receivingInterface)
                && record.receivingInterface != MessageRepository.optimisticOutboundMarker
        }

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
        case LXDeliveryMethod.paper.rawValue:
            self.deliveryMethod = "paper"
        default:
            self.deliveryMethod = nil
        }

        // Signal quality
        self.rssi = record.rssi
        self.snr = record.snr

        // Receiving interface from DB
        self.receivedInterface = record.receivingInterface

        // Reply
        self.replyToId = record.replyToId
        // replyToPreview is resolved later by the ViewModel
        self.replyToPreview = nil

        // Reactions from JSON
        if let json = record.reactionsJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            let localHashHex = localHash.map { String(format: "%02x", $0) }.joined()
            self.reactions = ReactionLedger.visibleReactions(dict).map { emoji, senders in
                ReactionDisplay(
                    emoji: emoji,
                    count: senders.count,
                    includesMe: senders.contains(localHashHex)
                )
            }.sorted { $0.emoji < $1.emoji }
        } else {
            self.reactions = []
        }

        // Extract attachment payloads from the persisted field map. Decoded
        // directly via `LxmfFieldCodec.unpack` because `LXMessage.pack()` /
        // `unpackFromBytes` are Compat stubs (returning empty Data / empty
        // LXMessage) — so the previous `LXMessage.unpackFromBytes(...)` path
        // *always* dropped the image/attachment fields on reload, even when
        // they were on the wire. See `MessageRecord.packedLxmf` for the
        // codec contract.
        if let fields = LxmfFieldCodec.unpack(record.packedLxmf) {
            self.renderer = MessageRenderer(fields: fields)
            // FIELD_IMAGE (0x06) = [format_string, image_bytes]
            if let imageField = fields[LXMessage.FIELD_IMAGE] as? [Any],
               imageField.count >= 2,
               let data = imageField[1] as? Data {
                // Format arrives as String when peers send a Swift String
                // (LxmfFieldCodec / LXMF-swift / Sideband-Python `image=[str,
                // bytes]`) and as Data when peers send raw bytes (LXMF-kt's
                // canonical `extension.toByteArray()`). Accept either so
                // round-trips with every interop partner work.
                let format: String?
                if let s = imageField[0] as? String { format = s }
                else if let d = imageField[0] as? Data { format = String(data: d, encoding: .utf8) }
                else { format = nil }
                if let format {
                    self.imageData = data
                    self.imageFormat = format
                }
            } else if let rawField = fields[LXMessage.FIELD_IMAGE] {
                // Image field exists but failed extraction — log for diagnosis
                logger.warning("Image field 0x06 present but extraction failed: type=\(String(describing: type(of: rawField))), value=\(String(describing: rawField).prefix(200))")
            }
            // FIELD_FILE_ATTACHMENTS (0x05) = [[filename, data], …]
            if let filesField = fields[LXMessage.FIELD_FILE_ATTACHMENTS] as? [Any] {
                var atts: [FileAttachment] = []
                for item in filesField {
                    if let pair = item as? [Any], pair.count >= 2,
                       let data = pair[1] as? Data {
                        let name: String
                        if let s = pair[0] as? String { name = s }
                        else if let d = pair[0] as? Data { name = String(data: d, encoding: .utf8) ?? "" }
                        else { continue }
                        atts.append(FileAttachment(name: name, data: data))
                    }
                }
                if !atts.isEmpty { self.attachments = atts }
            }

            // Fallback: extract reply_to from packed fields if DB column was nil
            if self.replyToId == nil,
               let appData = fields[LXMessage.FIELD_APP_DATA] as? [String: Any],
               let replyTo = appData["reply_to"] as? String {
                self.replyToId = replyTo
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
