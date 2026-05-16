//
//  MessagingViewModel.swift
//  Columba-iOS
//
//  ViewModel for messaging screen using @Observable macro.
//  Provides async message loading and sending via LXMFSwift.
//

import SwiftUI
import RNSAPI
import Observation
import os.log

/// ViewModel for the messaging screen.
///
/// Uses iOS 17+ @Observable macro for automatic SwiftUI observation.
/// Implements optimistic UI pattern - shows message immediately while
/// sending via LXMRouter.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class MessagingViewModel {
    // MARK: - Published Properties

    /// List of messages in chronological order (oldest first).
    public var messages: [Message] = []

    /// True while loading messages from database.
    public var isLoading: Bool = false

    /// True while loading older messages (pagination).
    public var isLoadingMore: Bool = false

    /// True when all messages have been loaded (no more pages).
    public var allMessagesLoaded: Bool = false

    /// Error message if operation failed, nil otherwise.
    public var errorMessage: String? = nil

    /// Message being replied to (set by UI when user swipes or taps Reply).
    public var replyToMessage: Message? = nil

    /// Page size for message fetching.
    private static let pageSize = 50

    // MARK: - Dependencies

    private let conversationHash: Data
    private let repository: MessageRepository
    private let appServices: AppServices
    private let settingsRepository = SettingsRepository()
    private let displayName: String?
    private let logger = Logger(subsystem: "network.columba.Columba", category: "MessagingViewModel")

    /// Observation token for incoming message notifications.
    private var notificationTask: Any?

    // MARK: - Initialization

    /// Create ViewModel for a specific conversation.
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes) of the conversation
    ///   - repository: MessageRepository for database access
    ///   - appServices: AppServices for router and identity access
    ///   - displayName: Optional display name for the peer
    public init(
        conversationHash: Data,
        repository: MessageRepository,
        appServices: AppServices,
        displayName: String? = nil
    ) {
        self.conversationHash = conversationHash
        self.repository = repository
        self.appServices = appServices
        self.displayName = displayName

        // Listen for incoming messages and reload when this conversation is affected
        notificationTask = NotificationCenter.default.addObserver(
            forName: IncomingMessageHandler.messageReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let sourceHash = notification.userInfo?["sourceHash"] as? Data,
               sourceHash != self.conversationHash {
                return
            }
            Task { @MainActor in
                await self.loadMessages()
            }
        }
    }

    deinit {
        if let token = notificationTask {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public Methods

    /// Load the most recent page of messages for this conversation.
    @MainActor
    public func loadMessages() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Ensure conversation exists
            try await repository.ensureConversation(conversationHash, displayName: displayName)

            // Fetch most recent page
            let records = try await repository.fetchMessageRecords(
                for: conversationHash, limit: Self.pageSize, offset: 0)
            let loaded = records.reversed()
                .map { Message(from: $0, localHash: appServices.localIdentityHash) }
                .filter { !$0.isEmpty }  // Hide telemetry-only messages (e.g. location sharing)

            // Resolve reply previews from loaded messages
            var resolvedMessages = loaded
            let contentById = Dictionary(loaded.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
            for i in resolvedMessages.indices {
                if let replyId = resolvedMessages[i].replyToId {
                    if let preview = contentById[replyId] {
                        resolvedMessages[i].replyToPreview = String(preview.prefix(80))
                    } else {
                        // DB fallback for messages not in current page
                        resolvedMessages[i].replyToPreview = await resolveReplyPreview(replyId)
                    }
                }
            }

            messages = resolvedMessages
            allMessagesLoaded = records.count < Self.pageSize

            // Mark as read
            try await repository.markConversationRead(conversationHash)

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load older messages when scrolling up.
    @MainActor
    public func loadMoreMessages() async {
        guard !isLoadingMore, !allMessagesLoaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let offset = messages.count
            let records = try await repository.fetchMessageRecords(
                for: conversationHash, limit: Self.pageSize, offset: offset)
            if records.isEmpty {
                allMessagesLoaded = true
                return
            }
            let older = records.reversed()
                .map { Message(from: $0, localHash: appServices.localIdentityHash) }
                .filter { !$0.isEmpty }  // Hide telemetry-only messages

            messages.insert(contentsOf: older, at: 0)
            if records.count < Self.pageSize {
                allMessagesLoaded = true
            }
        } catch {
            logger.error("Failed to load more messages: \(error.localizedDescription)")
        }
    }

    /// Send a text-only message (convenience wrapper).
    @MainActor
    public func sendMessage(text: String) async -> Bool {
        await sendMessage(text: text, imageData: nil, imageFormat: nil, attachments: nil)
    }

    /// Send a message with optional image, file attachments, and reply reference.
    ///
    /// - Parameters:
    ///   - text: Message text (can be empty if attachments provided)
    ///   - imageData: PNG/JPEG image bytes for FIELD_IMAGE
    ///   - imageFormat: Image format string ("png" or "jpeg")
    ///   - attachments: File attachments as (name, data) tuples for FIELD_FILE_ATTACHMENTS
    ///   - replyToId: Hex hash of message being replied to (optional)
    /// - Returns: True if message was sent successfully
    @MainActor
    public func sendMessage(
        text: String,
        imageData: Data?,
        imageFormat: String?,
        attachments: [(name: String, data: Data)]?,
        replyToId: String? = nil
    ) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || imageData != nil || (attachments != nil && !attachments!.isEmpty) else {
            return false
        }

        guard let identity = appServices.identity else {
            errorMessage = "Identity not initialized"
            return false
        }

        guard let router = appServices.router else {
            errorMessage = "Router not initialized"
            return false
        }

        // Always start with opportunistic (single encrypted packet, no link needed).
        // For large messages that exceed single-packet size, handleOutbound() will
        // auto-fallback using the fallbackMethod (direct or propagated per settings).
        // On failure, retry-via-relay handles the final propagated fallback.
        let settingsMethod = await settingsRepository.getDefaultDeliveryMethod()
        let fallbackForLargeMessages: LXDeliveryMethod = (settingsMethod == "propagated") ? .propagated : .direct

        // Build fields with icon appearance if set
        var fields: [UInt8: Any] = [:]
        if let icon = await settingsRepository.getIconAppearance() {
            fields[IconAppearance.fieldKey] = icon.toLXMFFieldValue()
        }

        // Add image field (FIELD_IMAGE = 0x06): [format_string, binary_data]
        if let imageData, let imageFormat {
            fields[LXMessage.FIELD_IMAGE] = [imageFormat, imageData] as [Any]
        }

        // Add file attachments field (FIELD_FILE_ATTACHMENTS = 0x05): [[name, data], ...]
        if let attachments, !attachments.isEmpty {
            fields[LXMessage.FIELD_FILE_ATTACHMENTS] = attachments.map { [$0.name, $0.data] as [Any] } as [Any]
        }

        // Add reply reference (FIELD_APP_DATA = 0x10)
        if let replyToId {
            fields[LXMessage.FIELD_APP_DATA] = ["reply_to": replyToId] as [String: Any]
        }

        // Create outbound LXMF message — always opportunistic first
        var lxMessage = LXMessage(
            destinationHash: conversationHash,
            sourceIdentity: identity,
            content: trimmedText.data(using: .utf8) ?? Data(),
            title: Data(),
            fields: fields.isEmpty ? nil : fields,
            desiredMethod: .opportunistic
        )
        lxMessage.fallbackMethod = fallbackForLargeMessages

        // Generate temporary hash for optimistic UI
        let optimisticId = UUID().uuidString
        lxMessage.hash = optimisticId.data(using: .utf8)!

        // Build reply preview for optimistic display
        let replyPreview: String? = {
            guard let replyToId else { return nil }
            if let msg = messages.first(where: { $0.id == replyToId }) {
                return String(msg.content.prefix(80))
            }
            return nil
        }()

        // Create UI message for immediate display (include attachments for preview)
        let optimisticMessage = Message(
            id: optimisticId,
            content: trimmedText,
            timestamp: Date(),
            isFromMe: true,
            deliveryStatus: .sending,
            imageData: imageData,
            imageFormat: imageFormat,
            attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) },
            replyToId: replyToId,
            replyToPreview: replyPreview
        )

        // Add to UI immediately
        withAnimation(.easeOut(duration: 0.25)) {
            messages.append(optimisticMessage)
        }

        do {
            // Send via router (router saves to DB internally via Task.detached)
            try await router.handleOutbound(&lxMessage)

            // Replace optimistic message with real one (using actual hash from pack)
            let realId = lxMessage.hash.map { String(format: "%02x", $0) }.joined()
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index] = Message(
                        id: realId,
                        content: trimmedText,
                        timestamp: Date(timeIntervalSince1970: lxMessage.timestamp),
                        isFromMe: true,
                        deliveryStatus: .sent,
                        imageData: imageData,
                        imageFormat: imageFormat,
                        attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) },
                        replyToId: replyToId,
                        replyToPreview: replyPreview
                    )
                }
            }

            return true
        } catch {
            // Retry via relay if enabled
            let retryViaRelay = await settingsRepository.getRetryViaRelay()
            if retryViaRelay {
                logger.info("[MSG_VM] Delivery failed, retrying via relay")

                // Update UI to show retrying
                if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages[index].deliveryStatus = .sending
                    }
                }

                // Create new message with propagated method
                var retryMessage = LXMessage(
                    destinationHash: conversationHash,
                    sourceIdentity: identity,
                    content: trimmedText.data(using: .utf8) ?? Data(),
                    title: Data(),
                    fields: fields.isEmpty ? nil : fields,
                    desiredMethod: .propagated
                )

                do {
                    // Router saves to DB internally
                    try await router.handleOutbound(&retryMessage)
                    let realId = retryMessage.hash.map { String(format: "%02x", $0) }.joined()
                    if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            messages[index] = Message(
                                id: realId,
                                content: trimmedText,
                                timestamp: Date(timeIntervalSince1970: retryMessage.timestamp),
                                isFromMe: true,
                                deliveryStatus: .sent,
                                imageData: imageData,
                                imageFormat: imageFormat,
                                attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) },
                                replyToId: replyToId,
                                replyToPreview: replyPreview
                            )
                        }
                    }
                    return true
                } catch {
                    logger.error("[MSG_VM] Relay retry also failed: \(error.localizedDescription)")
                }
            }

            // Update to failed status with real hash so retry can delete from DB
            let realHash = lxMessage.hash
            let failedId = realHash.map { String(format: "%02x", $0) }.joined()
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index].deliveryStatus = .failed
                    messages[index].messageHash = realHash
                    if !failedId.isEmpty {
                        messages[index] = Message(
                            id: failedId,
                            content: messages[index].content,
                            timestamp: messages[index].timestamp,
                            isFromMe: true,
                            deliveryStatus: .failed,
                            replyToId: replyToId,
                            replyToPreview: replyPreview
                        )
                        messages[index].messageHash = realHash
                    }
                }
            }
            errorMessage = "Failed to send: \(error.localizedDescription)"
            return false
        }
    }

    /// Retry sending a failed message.
    @MainActor
    public func retryMessage(messageId: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].deliveryStatus == .failed else {
            return
        }

        let failedMessage = messages[index]

        // Delete from database if we have the hash
        if let hash = failedMessage.messageHash {
            try? await repository.deleteMessage(hash)
        }

        // Remove from UI
        _ = withAnimation {
            messages.remove(at: index)
        }

        // Resend
        _ = await sendMessage(text: failedMessage.content)
    }

    /// Delete a message from the conversation.
    @MainActor
    public func deleteMessage(messageId: String, messageHash: Data?) async {
        // Remove from UI immediately
        withAnimation {
            messages.removeAll { $0.id == messageId }
        }

        // Delete from database if we have the hash
        if let hash = messageHash {
            do {
                try await repository.deleteMessage(hash)
            } catch {
                logger.error("Failed to delete message: \(error.localizedDescription)")
            }
        }
    }

    /// Check if a message is from the local user.
    public func isMessageFromMe(_ message: Message) -> Bool {
        message.isFromMe
    }

    // MARK: - Reactions

    /// Send an emoji reaction to a message (toggle: adds if not present, removes if present).
    @MainActor
    public func sendReaction(targetMessageId: String, targetMessageHash: Data?, emoji: String) async {
        guard let hash = targetMessageHash else { return }
        guard let identity = appServices.identity, let router = appServices.router else { return }

        let localHashHex = appServices.localIdentityHash.map { String(format: "%02x", $0) }.joined()

        // Read-modify-write reactions in DB
        var reactionsDict: [String: [String]] = [:]
        if let json = try? await repository.getReactionsJson(hash),
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            reactionsDict = dict
        }

        // Toggle
        var senders = reactionsDict[emoji] ?? []
        if senders.contains(localHashHex) {
            senders.removeAll { $0 == localHashHex }
        } else {
            senders.append(localHashHex)
        }
        if senders.isEmpty {
            reactionsDict.removeValue(forKey: emoji)
        } else {
            reactionsDict[emoji] = senders
        }

        // Save to DB
        if let jsonData = try? JSONSerialization.data(withJSONObject: reactionsDict),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            try? await repository.updateReactions(hash, reactionsJson: jsonStr)
        }

        // Update UI
        if let index = messages.firstIndex(where: { $0.id == targetMessageId }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                messages[index].reactions = reactionsDict.map { emojiKey, senderList in
                    ReactionDisplay(
                        emoji: emojiKey,
                        count: senderList.count,
                        includesMe: senderList.contains(localHashHex)
                    )
                }.sorted { $0.emoji < $1.emoji }
            }
        }

        // Send reaction LXMF message (empty content)
        var fields: [UInt8: Any] = [:]
        fields[LXMessage.FIELD_APP_DATA] = [
            "reaction_to": targetMessageId,
            "emoji": emoji,
            "sender": localHashHex
        ] as [String: Any]

        var lxMessage = LXMessage(
            destinationHash: conversationHash,
            sourceIdentity: identity,
            content: Data(),
            title: Data(),
            fields: fields,
            desiredMethod: .opportunistic
        )

        do {
            try await router.handleOutbound(&lxMessage)
        } catch {
            logger.error("Failed to send reaction: \(error.localizedDescription)")
        }
    }

    // MARK: - Reply Preview Resolution

    /// Resolve reply preview text for a message hash (DB fallback when not in loaded messages).
    private func resolveReplyPreview(_ replyToIdHex: String) async -> String? {
        guard let hashData = Self.hexToData(replyToIdHex) else { return nil }
        guard let record = try? await repository.getMessageRecord(id: hashData) else { return nil }
        guard let content = String(data: record.content, encoding: .utf8), !content.isEmpty else { return nil }
        return String(content.prefix(80))
    }

    /// Convert hex string to Data.
    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var chars = hex[hex.startIndex...]
        while chars.count >= 2 {
            let end = chars.index(chars.startIndex, offsetBy: 2)
            guard let byte = UInt8(chars[chars.startIndex..<end], radix: 16) else { return nil }
            data.append(byte)
            chars = chars[end...]
        }
        return data
    }
}
