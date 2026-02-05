//
//  ChatsViewModel.swift
//  Columba-iOS
//
//  ViewModel for the chats screen using @Observable macro.
//  Manages conversation list data and refresh operations.
//

import Foundation
import Observation

// MARK: - Conversation Model

/// Represents a conversation in the chats list.
public struct Conversation: Identifiable, Equatable, Hashable {
    public let id: String
    public let destinationHash: Data
    public var displayName: String?
    public var lastMessageTimestamp: Date
    public var lastMessagePreview: String?
    public var unreadCount: Int
    public var isFavorite: Bool

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
/// Provides mock data for development and integration point for MessageRepository.
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

    // TODO: Inject MessageRepository when available
    // private let repository: MessageRepository

    // MARK: - Initialization

    public init() {
        // Load mock data for development
        loadMockData()
    }

    // MARK: - Public Methods

    /// Load conversations from storage.
    ///
    /// Integration point for MessageRepository.
    @MainActor
    public func loadConversations() async {
        isLoading = true
        defer { isLoading = false }

        // Simulate network delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        // TODO: Replace with actual repository call
        // conversations = try await repository.fetchConversations()

        // For now, use mock data
        loadMockData()
    }

    /// Refresh conversations from storage.
    @MainActor
    public func refreshConversations() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Simulate network delay
        try? await Task.sleep(nanoseconds: 800_000_000)

        // TODO: Replace with actual repository call
        loadMockData()
    }

    /// Toggle favorite status for a conversation.
    ///
    /// - Parameter conversation: The conversation to toggle
    @MainActor
    public func toggleFavorite(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        conversations[index].isFavorite.toggle()

        // TODO: Persist favorite status to storage
    }

    /// Delete a conversation.
    ///
    /// - Parameter conversation: The conversation to delete
    @MainActor
    public func deleteConversation(_ conversation: Conversation) async {
        conversations.removeAll { $0.id == conversation.id }

        // TODO: Delete from repository
        // try await repository.deleteConversation(conversation.destinationHash)
    }

    // MARK: - Private Methods

    /// Load mock data for development and preview.
    private func loadMockData() {
        conversations = [
            Conversation(
                destinationHash: Data([0xDB, 0x3F, 0xFD, 0x25, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
                displayName: nil,
                lastMessageTimestamp: Date().addingTimeInterval(-60),
                lastMessagePreview: "Hi there!",
                unreadCount: 0,
                isFavorite: false
            ),
            Conversation(
                destinationHash: Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]),
                displayName: "Alice",
                lastMessageTimestamp: Date().addingTimeInterval(-3600),
                lastMessagePreview: "Have you set up your Reticulum node yet?",
                unreadCount: 2,
                isFavorite: true
            ),
            Conversation(
                destinationHash: Data([0xC1, 0xD2, 0xE3, 0xF4, 0x05, 0x16, 0x27, 0x38, 0x49, 0x5A, 0x6B, 0x7C, 0x8D, 0x9E, 0xAF, 0xB0]),
                displayName: "Bob",
                lastMessageTimestamp: Date().addingTimeInterval(-86400),
                lastMessagePreview: "The mesh network is working great now",
                unreadCount: 0,
                isFavorite: false
            )
        ]
    }
}
