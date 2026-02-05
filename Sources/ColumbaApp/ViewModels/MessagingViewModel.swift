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

    /// Error message if operation failed, nil otherwise.
    public var errorMessage: String? = nil

    // MARK: - Dependencies

    private let conversationHash: Data
    private let repository: MessageRepository
    private let appServices: AppServices
    private let displayName: String?

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
            // Reload if the message is for this conversation, or always reload
            // (sourceHash may be the peer's hash which matches our conversationHash)
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

    /// Load messages for this conversation.
    @MainActor
    public func loadMessages() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Ensure conversation exists
            try await repository.ensureConversation(conversationHash, displayName: displayName)

            // Fetch messages (returns newest first, we reverse for chronological)
            let lxMessages = try await repository.fetchMessages(for: conversationHash)
            messages = lxMessages.reversed().map { Message(from: $0, localHash: appServices.localIdentityHash) }

            // Mark as read
            try await repository.markConversationRead(conversationHash)

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Send a message with optimistic UI.
    ///
    /// - Parameter text: Message text to send
    /// - Returns: True if message was sent successfully
    @MainActor
    public func sendMessage(text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        guard let identity = appServices.identity else {
            errorMessage = "Identity not initialized"
            return false
        }

        guard let router = appServices.router else {
            errorMessage = "Router not initialized"
            return false
        }

        // Create outbound LXMF message
        var lxMessage = LXMessage(
            destinationHash: conversationHash,
            sourceIdentity: identity,
            content: trimmedText.data(using: .utf8) ?? Data(),
            title: Data(),
            fields: nil,
            desiredMethod: .opportunistic
        )

        // Generate temporary hash for optimistic UI
        let optimisticId = UUID().uuidString
        lxMessage.hash = optimisticId.data(using: .utf8)!

        // Create UI message for immediate display
        let optimisticMessage = Message(
            id: optimisticId,
            content: trimmedText,
            timestamp: Date(),
            isFromMe: true,
            deliveryStatus: .sending
        )

        // Add to UI immediately
        withAnimation(.easeOut(duration: 0.25)) {
            messages.append(optimisticMessage)
        }

        do {
            // Send via router
            try await router.handleOutbound(&lxMessage)

            // Update UI with sent status
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index].deliveryStatus = .sent
                }
            }

            // Save to database
            try await repository.saveMessage(lxMessage)

            return true
        } catch {
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
