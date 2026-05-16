//
//  MessageRepository.swift
//  ColumbaApp
//
//  Async wrapper for LXMFDatabase operations, providing thread-safe
//  message and conversation access for SwiftUI ViewModels.
//

import Foundation
import RNSAPI

/// Actor for thread-safe message database operations.
///
/// Wraps LXMFDatabase to provide async methods for ViewModel consumption.
/// All operations are serialized through the actor to ensure thread safety.
public actor MessageRepository {
    // MARK: - Properties

    private let database: LXMFDatabase

    // MARK: - Initialization

    /// Create repository with database instance.
    ///
    /// - Parameter database: LXMFDatabase instance to wrap
    public init(database: LXMFDatabase) {
        self.database = database
    }

    // MARK: - Conversation Operations

    /// Fetch all conversations, sorted by most recent message.
    ///
    /// - Parameters:
    ///   - limit: Maximum number of conversations to return (default 100)
    ///   - offset: Number of conversations to skip (default 0)
    /// - Returns: Array of ConversationRecord ordered by last message timestamp
    /// - Throws: DatabaseError if query fails
    public func fetchConversations(limit: Int = 100, offset: Int = 0) async throws -> [ConversationRecord] {
        try await database.getConversations(limit: limit, offset: offset)
    }

    /// Fetch a single conversation by destination hash.
    ///
    /// - Parameter conversationHash: Destination hash (16 bytes) of the conversation
    /// - Returns: ConversationRecord if found, nil otherwise
    /// - Throws: DatabaseError if query fails
    public func fetchConversation(_ conversationHash: Data) async throws -> ConversationRecord? {
        try await database.getConversation(hash: conversationHash)
    }

    /// Mark conversation as read (reset unread count).
    ///
    /// Updates the conversation record to set unreadCount = 0 and isUnread = 0.
    ///
    /// - Parameter conversationHash: Destination hash (16 bytes) of the conversation
    /// - Throws: DatabaseError if update fails
    public func markConversationRead(_ conversationHash: Data) async throws {
        try await database.markConversationRead(hash: conversationHash)
    }

    /// Set the unread count for a conversation (e.g. mark as unread with count=1).
    public func setUnreadCount(_ conversationHash: Data, count: Int) async throws {
        try await database.setUnreadCount(hash: conversationHash, count: count)
    }

    /// Delete conversation and all its messages.
    ///
    /// Cascades deletion to all messages in the conversation due to foreign key constraint.
    ///
    /// - Parameter conversationHash: Destination hash (16 bytes) of the conversation
    /// - Throws: DatabaseError if deletion fails
    public func deleteConversation(_ conversationHash: Data) async throws {
        try await database.deleteConversation(hash: conversationHash)
    }

    /// Delete a single message by its ID hash.
    ///
    /// - Parameter messageId: Message hash (32 bytes)
    /// - Throws: DatabaseError if deletion fails
    public func deleteMessage(_ messageId: Data) async throws {
        try await database.deleteMessage(id: messageId)
    }

    /// Ensure a conversation exists for a destination.
    ///
    /// Creates a new conversation record if one doesn't exist.
    /// If conversation already exists, updates the display name if provided and not already set.
    /// This is used when starting a chat from announces to ensure the conversation
    /// appears in the conversation list.
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes) of the conversation
    ///   - displayName: Display name for the conversation (optional)
    /// - Throws: DatabaseError if operation fails
    public func ensureConversation(_ conversationHash: Data, displayName: String?) async throws {
        try await database.ensureConversation(hash: conversationHash, displayName: displayName)
    }

    /// Set favorite status for a conversation.
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes)
    ///   - isFavorite: Whether to mark as favorite
    /// - Throws: DatabaseError
    public func setFavorite(_ conversationHash: Data, isFavorite: Bool) async throws {
        try await database.setFavorite(hash: conversationHash, isFavorite: isFavorite)
    }

    /// Set pinned status for a conversation.
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes)
    ///   - isPinned: Whether to pin the conversation
    /// - Throws: DatabaseError
    public func setPinned(_ conversationHash: Data, isPinned: Bool) async throws {
        try await database.setPinned(hash: conversationHash, isPinned: isPinned)
    }

    /// Update display name for a conversation.
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes)
    ///   - displayName: New display name (nil to clear)
    /// - Throws: DatabaseError
    public func updateDisplayName(_ conversationHash: Data, displayName: String?) async throws {
        try await database.updateDisplayName(hash: conversationHash, displayName: displayName)
    }

    // MARK: - Icon Appearance

    /// Update peer icon appearance for a conversation.
    ///
    /// - Parameters:
    ///   - hash: Destination hash (16 bytes)
    ///   - icon: IconAppearance to save
    /// - Throws: DatabaseError
    public func updatePeerIcon(_ hash: Data, icon: IconAppearance) async throws {
        try await database.updatePeerIcon(hash, iconName: icon.iconName, fgColor: icon.foregroundColor, bgColor: icon.backgroundColor)
    }

    /// Get peer icon appearance for a conversation.
    ///
    /// - Parameter hash: Destination hash (16 bytes)
    /// - Returns: IconAppearance if set, nil otherwise
    /// - Throws: DatabaseError
    public func getPeerIcon(_ hash: Data) async throws -> IconAppearance? {
        try await database.getPeerIcon(hash)
    }

    // MARK: - Reply & Reaction Operations

    /// Update the reply_to_id for a message.
    public func updateReplyToId(_ messageId: Data, replyToId: String) async throws {
        try await database.updateReplyToId(messageId: messageId, replyToId: replyToId)
    }

    /// Update the reactions_json for a message.
    public func updateReactions(_ messageId: Data, reactionsJson: String) async throws {
        try await database.updateReactions(messageId: messageId, reactionsJson: reactionsJson)
    }

    /// Get the reactions_json for a message.
    public func getReactionsJson(_ messageId: Data) async throws -> String? {
        try await database.getReactionsJson(messageId: messageId)
    }

    /// Get a single message record by ID (lightweight).
    public func getMessageRecord(id: Data) async throws -> MessageRecord? {
        try await database.getMessageRecord(id: id)
    }

    // MARK: - Message Operations

    /// Fetch messages for a specific conversation.
    ///
    /// Returns messages ordered by timestamp descending (newest first).
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes) of the conversation
    ///   - limit: Maximum number of messages to return (default 50)
    ///   - offset: Number of messages to skip (default 0)
    /// - Returns: Array of LXMessage ordered by timestamp descending
    /// - Throws: DatabaseError or LXMFError if query fails
    public func fetchMessages(for conversationHash: Data, limit: Int = 50, offset: Int = 0) async throws -> [LXMessage] {
        try await database.getMessages(forConversation: conversationHash, limit: limit, offset: offset)
    }

    /// Fetch raw message records for a conversation (no LXMessage unpacking).
    ///
    /// Returns lightweight MessageRecord structs directly from database,
    /// avoiding expensive MessagePack + SHA256 + Ed25519 operations.
    /// Use this for UI display where only metadata is needed.
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes) of the conversation
    ///   - limit: Maximum number of records to return (default 50)
    ///   - offset: Number of records to skip (default 0)
    /// - Returns: Array of MessageRecord ordered by timestamp descending
    /// - Throws: DatabaseError if query fails
    public func fetchMessageRecords(for conversationHash: Data, limit: Int = 50, offset: Int = 0) async throws -> [MessageRecord] {
        try await database.getMessageRecords(forConversation: conversationHash, limit: limit, offset: offset)
    }

    /// Save a new outbound message.
    ///
    /// Persists the message to database and updates the conversation record.
    ///
    /// - Parameter message: LXMessage to save (must be packed)
    /// - Throws: DatabaseError or LXMFError if save fails
    public func saveMessage(_ message: LXMessage) async throws {
        try await database.saveMessage(message)
    }

    /// Get message by ID.
    ///
    /// - Parameter id: Message hash (32 bytes)
    /// - Returns: LXMessage if found, nil otherwise
    /// - Throws: DatabaseError or LXMFError if retrieval fails
    public func getMessage(id: Data) async throws -> LXMessage? {
        try await database.getMessage(id: id)
    }

    /// Check if message exists.
    ///
    /// - Parameter id: Message hash (32 bytes)
    /// - Returns: True if message exists in database
    /// - Throws: DatabaseError if query fails
    public func hasMessage(id: Data) async throws -> Bool {
        try await database.hasMessage(id: id)
    }

    /// Update message delivery state.
    ///
    /// - Parameters:
    ///   - id: Message hash (32 bytes)
    ///   - state: New delivery state
    /// - Throws: DatabaseError if update fails
    public func updateMessageState(id: Data, state: LXMessageState) async throws {
        try await database.updateMessageState(id: id, state: state)
    }

    /// Load pending outbound messages.
    ///
    /// Returns messages in OUTBOUND state waiting to be sent.
    ///
    /// - Returns: Array of LXMessage with state == .outbound
    /// - Throws: DatabaseError or LXMFError if query fails
    public func loadPendingOutbound() async throws -> [LXMessage] {
        try await database.loadPendingOutbound()
    }

    /// Load failed outbound messages.
    ///
    /// Returns messages in FAILED state for retry or inspection.
    ///
    /// - Returns: Array of LXMessage with state == .failed
    /// - Throws: DatabaseError or LXMFError if query fails
    public func loadFailedOutbound() async throws -> [LXMessage] {
        try await database.loadFailedOutbound()
    }
}
