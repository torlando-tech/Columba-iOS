import Foundation

/// A conversation-list row backed by the Python-owned SQLite store.
///
/// In Phase 2 this is what `MessageRepository` (the new Python-backed
/// implementation) returns to ChatsView for the conversation list. The schema is
/// owned in Python (`app/columba_store.py`) and read by Swift via GRDB-read or
/// stdlib SQLite — see the migration plan for the columns.
public struct PyConversation: Identifiable, Equatable, Sendable {
    public let destHash: String
    public var displayName: String
    public var lastMessage: String?
    public var lastMessageAt: Date?
    public var unreadCount: Int
    public var isFavorite: Bool
    public var isPinned: Bool

    public var id: String { destHash }

    public init(
        destHash: String,
        displayName: String,
        lastMessage: String? = nil,
        lastMessageAt: Date? = nil,
        unreadCount: Int = 0,
        isFavorite: Bool = false,
        isPinned: Bool = false
    ) {
        self.destHash = destHash
        self.displayName = displayName
        self.lastMessage = lastMessage
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.isFavorite = isFavorite
        self.isPinned = isPinned
    }
}
