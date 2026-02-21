//
//  MessagingViewModel.swift
//  Columba-iOS
//
//  ViewModel for messaging screen using @Observable macro.
//  Provides async message loading and sending via LXMFSwift.
//

import SwiftUI
import Observation
import LXMFSwift
import ReticulumSwift
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

    /// Page size for message fetching.
    private static let pageSize = 50

    // MARK: - Dependencies

    private let conversationHash: Data
    private let repository: MessageRepository
    private let appServices: AppServices
    private let settingsRepository = SettingsRepository()
    private let displayName: String?
    private let logger = Logger(subsystem: "com.columba.app", category: "MessagingViewModel")

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
            messages = records.reversed().map { Message(from: $0, localHash: appServices.localIdentityHash) }
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
            let older = records.reversed().map { Message(from: $0, localHash: appServices.localIdentityHash) }
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

    /// Send a message with optional image and file attachments.
    ///
    /// - Parameters:
    ///   - text: Message text (can be empty if attachments provided)
    ///   - imageData: PNG/JPEG image bytes for FIELD_IMAGE
    ///   - imageFormat: Image format string ("png" or "jpeg")
    ///   - attachments: File attachments as (name, data) tuples for FIELD_FILE_ATTACHMENTS
    /// - Returns: True if message was sent successfully
    @MainActor
    public func sendMessage(
        text: String,
        imageData: Data?,
        imageFormat: String?,
        attachments: [(name: String, data: Data)]?
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

        // Create UI message for immediate display (include attachments for preview)
        let optimisticMessage = Message(
            id: optimisticId,
            content: trimmedText,
            timestamp: Date(),
            isFromMe: true,
            deliveryStatus: .sending,
            imageData: imageData,
            imageFormat: imageFormat,
            attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) }
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
                        attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) }
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
                                attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) }
                            )
                        }
                    }
                    return true
                } catch {
                    logger.error("[MSG_VM] Relay retry also failed: \(error.localizedDescription)")
                }
            }

            // Update to failed status
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index].deliveryStatus = .failed
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

        let content = messages[index].content

        // Remove failed message
        withAnimation {
            messages.remove(at: index)
        }

        // Resend
        _ = await sendMessage(text: content)
    }

    /// Check if a message is from the local user.
    public func isMessageFromMe(_ message: Message) -> Bool {
        message.isFromMe
    }
}
