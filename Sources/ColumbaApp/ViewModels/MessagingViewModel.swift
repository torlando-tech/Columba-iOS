//
//  MessagingViewModel.swift
//  Columba-iOS
//
//  ViewModel for messaging screen using @Observable macro.
//  Provides async message loading and sending with optimistic UI.
//

import SwiftUI
import Observation

/// ViewModel for the messaging screen.
///
/// Uses iOS 17+ @Observable macro for automatic SwiftUI observation.
/// Implements optimistic UI pattern - shows message immediately while
/// persisting for network extension processing.
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

    private let conversationId: String?

    // MARK: - Initialization

    /// Create ViewModel for a specific conversation.
    ///
    /// - Parameter conversationId: Optional conversation identifier for loading messages
    public init(conversationId: String? = nil) {
        self.conversationId = conversationId
    }

    // MARK: - Public Methods

    /// Load messages for this conversation.
    ///
    /// Fetches messages from database and updates the messages array.
    @MainActor
    public func loadMessages() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // In a real implementation, this would fetch from MessageRepository
            // For now, load sample messages for preview/testing
            if messages.isEmpty {
                messages = createSampleMessages()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Send a message with optimistic UI.
    ///
    /// Creates an optimistic message shown immediately in the UI, then
    /// persists to database for network extension processing.
    ///
    /// - Parameter text: Message text to send
    @MainActor
    public func sendMessage(text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Create optimistic message
        let optimisticId = UUID().uuidString
        var newMessage = Message(
            id: optimisticId,
            content: trimmedText,
            timestamp: Date(),
            isFromMe: true,
            deliveryStatus: .sending
        )

        // Add to UI immediately with animation
        withAnimation(.easeOut(duration: 0.25)) {
            messages.append(newMessage)
        }

        do {
            // Simulate network delay for demo
            // In real implementation: try await repository.saveMessage(outboundMessage)
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            // Update to sent status
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index].deliveryStatus = .sent
                }
            }

            // Simulate delivery confirmation
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index].deliveryStatus = .delivered
                }
            }

        } catch {
            // Update to failed status
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index].deliveryStatus = .failed
                }
            }
            errorMessage = "Failed to send: \(error.localizedDescription)"
        }
    }

    /// Retry sending a failed message.
    ///
    /// - Parameter messageId: ID of the message to retry
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
        await sendMessage(text: content)
    }

    // MARK: - Private Methods

    /// Create sample messages for preview/testing.
    private func createSampleMessages() -> [Message] {
        [
            Message(
                id: "1",
                content: "Hello!",
                timestamp: Date().addingTimeInterval(-300),
                isFromMe: false
            ),
            Message(
                id: "2",
                content: "Hi there!",
                timestamp: Date().addingTimeInterval(-60),
                isFromMe: true,
                deliveryStatus: .delivered
            )
        ]
    }
}

// MARK: - Preview Helpers

extension MessagingViewModel {
    /// Create a preview ViewModel with sample messages.
    static var preview: MessagingViewModel {
        let viewModel = MessagingViewModel()
        viewModel.messages = [
            Message(
                id: "1",
                content: "Hello!",
                timestamp: Date().addingTimeInterval(-300),
                isFromMe: false
            ),
            Message(
                id: "2",
                content: "Hi there!",
                timestamp: Date(),
                isFromMe: true,
                deliveryStatus: .delivered
            )
        ]
        return viewModel
    }
}
