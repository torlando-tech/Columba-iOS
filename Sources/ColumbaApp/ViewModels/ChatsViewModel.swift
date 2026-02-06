//
//  ChatsViewModel.swift
//  Columba-iOS
//
//  ViewModel for the chats screen using @Observable macro.
//  Manages conversation list data from MessageRepository.
//

import Foundation
import Observation
import LXMFSwift

// MARK: - Conversation Model

/// Represents a conversation in the chats list.
/// Wraps ConversationRecord from LXMFSwift with UI-specific properties.
public struct Conversation: Identifiable, Equatable, Hashable {
    public let id: String
    public let destinationHash: Data
    public var displayName: String?
    public var lastMessageTimestamp: Date
    public var lastMessagePreview: String?
    public var unreadCount: Int
    public var isFavorite: Bool
    public var iconName: String?
    public var iconFgColor: String?
    public var iconBgColor: String?

    /// Display name with fallback to truncated hash.
    public var peerName: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        // Fallback: "Peer " + first 8 hex chars uppercase
        let hexString = destinationHash
            .prefix(4)
            .map { String(format: "%02X", $0) }
            .joined()
        return "Peer \(hexString)"
    }

    /// Formatted relative timestamp for display.
    public var relativeTimestamp: String {
        let now = Date()
        let interval = now.timeIntervalSince(lastMessageTimestamp)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: lastMessageTimestamp)
        }
    }

    /// Create from LXMFSwift ConversationRecord.
    public init(from record: ConversationRecord) {
        self.id = record.destinationHash.map { String(format: "%02x", $0) }.joined()
        self.destinationHash = record.destinationHash
        self.displayName = record.displayName
        self.lastMessageTimestamp = Date(timeIntervalSince1970: record.lastMessageTimestamp)
        self.lastMessagePreview = record.lastMessagePreview
        self.unreadCount = record.unreadCount
        self.isFavorite = record.isFavorite != 0
        self.iconName = record.iconName
        self.iconFgColor = record.iconFgColor
        self.iconBgColor = record.iconBgColor
    }

    public init(
        id: String = UUID().uuidString,
        destinationHash: Data,
        displayName: String? = nil,
        lastMessageTimestamp: Date,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.lastMessageTimestamp = lastMessageTimestamp
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
        self.isFavorite = isFavorite
    }
}

// MARK: - ChatsViewModel

/// ViewModel for the chats screen.
///
/// Uses iOS 17+ @Observable macro for automatic SwiftUI observation.
/// Fetches conversation data from MessageRepository.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class ChatsViewModel {
    // MARK: - Published Properties

    /// List of conversations, sorted by most recent message first.
    public var conversations: [Conversation] = []

    /// True while loading or refreshing conversations.
    public var isLoading: Bool = false

    /// True while performing a refresh operation.
    public var isRefreshing: Bool = false

    /// Search query text.
    public var searchQuery: String = ""

    /// Error message if load failed, nil otherwise.
    public var errorMessage: String? = nil

    // MARK: - Computed Properties

    /// Number of conversations for subtitle display.
    public var conversationCountText: String {
        let count = filteredConversations.count
        return count == 1 ? "1 conversation" : "\(count) conversations"
    }

    /// Filtered conversations based on search query.
    public var filteredConversations: [Conversation] {
        guard !searchQuery.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.peerName.localizedCaseInsensitiveContains(searchQuery) ||
            (conversation.lastMessagePreview?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    // MARK: - Dependencies

    private let repository: MessageRepository
    private let notificationObserver: NotificationObserver
    private var inProcessObserver: NSObjectProtocol?

    // MARK: - Initialization

    public init(repository: MessageRepository, notificationObserver: NotificationObserver) {
        self.repository = repository
        self.notificationObserver = notificationObserver

        // Register for Darwin notifications (cross-process, fires before DB save)
        notificationObserver.onNewMessage { [weak self] in
            Task { @MainActor in
                await self?.loadConversations()
            }
        }

        // Register for in-process notifications (fires after DB save — this is the reliable one)
        inProcessObserver = NotificationCenter.default.addObserver(
            forName: IncomingMessageHandler.messageReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadConversations()
            }
        }
    }

    deinit {
        if let observer = inProcessObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    /// Load conversations from storage.
    @MainActor
    public func loadConversations() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let records = try await repository.fetchConversations()
            conversations = records.map { Conversation(from: $0) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh conversations from storage.
    @MainActor
    public func refreshConversations() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let records = try await repository.fetchConversations()
            conversations = records.map { Conversation(from: $0) }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggle favorite status for a conversation and persist to database.
    ///
    /// - Parameter conversation: The conversation to toggle
    @MainActor
    public func toggleFavorite(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        let newValue = !conversations[index].isFavorite
        conversations[index].isFavorite = newValue
        Task {
            try? await repository.setFavorite(conversation.destinationHash, isFavorite: newValue)
        }
    }

    /// Delete a conversation.
    ///
    /// - Parameter conversation: The conversation to delete
    @MainActor
    public func deleteConversation(_ conversation: Conversation) async {
        do {
            try await repository.deleteConversation(conversation.destinationHash)
            conversations.removeAll { $0.id == conversation.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
