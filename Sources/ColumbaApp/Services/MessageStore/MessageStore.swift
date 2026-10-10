//
//  MessageStore.swift
//  ColumbaApp
//
//  App-owned GRDB store for the shared `messages` + `conversations` tables.
//
//  ── ANDROID-PARITY STORE (Track: app-owned store) ─────────────────────────
//  Lifted from the LXMFSwift package's `Storage/LXMFDatabase.swift` and re-scoped
//  to the app target so the store is app-owned and does NOT depend on the wire
//  library (LXMFSwift / ReticulumSwift) - the same shape as Android, whose
//  `:data` Room store has zero dependency on the RNS library.
//
//  The SCHEMA IS FROZEN. The migration bodies below are byte-for-byte identical
//  to the LXMFSwift `LXMFDatabase` migrations (v1..v6): the Network Extension's
//  embedded Python node opens this same file as the writer and INSERTs inbound
//  rows into these exact tables (rns_bridge.py `_write_inbound_to_grdb`), so any
//  change here would break the cross-process store. Do not alter columns, types,
//  defaults, PKs, FKs, or index names without a coordinated change to the Python
//  writer and a migration.
//
//  The ONLY structural change from the lifted file: the LXMessage-returning
//  methods (`saveMessage(LXMessage)`, `getMessage(id:)`, `getMessages(...)`,
//  `loadPendingOutbound()`, `loadFailedOutbound()`, `updateConversation(for:)`)
//  are replaced by row-based equivalents operating on `MessageRow` /
//  `ConversationStoreRow`. The app (MessageRepository) builds rows from RNSAPI domain
//  types; the wire codec stays in the collector, not the store.
//

import Foundation
import GRDB

/// Actor for thread-safe message store operations.
///
/// Manages SQLite database with WAL mode for concurrent access. Stores messages
/// with full packed bytes for retransmission.
public actor MessageStore {
    // MARK: - Properties

    private let dbPool: DatabasePool

    // MARK: - Initialization

    /// Create or open the message store.
    ///
    /// - Parameter path: Database file path
    /// - Throws: DatabaseError if initialization fails
    public init(path: String, readonly: Bool = false) throws {
        // App <-> Network-Extension share this database across processes (Model B).
        // The writer (the NE) must survive iOS's 0xDEAD10CC "file busy while suspended"
        // kill; the app opens read-only with `readonly: true`. (GRDB DatabaseSharing.)
        var config = Configuration()
        config.readonly = readonly
        // Suspend cleanly when iOS backgrounds the process holding a lock, instead of
        // being 0xDEAD10CC-killed.
        config.observesSuspensionNotifications = true
        // Take write locks up front to avoid cross-process SQLITE_BUSY upgrade
        // deadlocks. Writer-only: a read-only pool issues deferred read transactions
        // regardless, so this would be dead (and misleading) config on the reader.
        if !readonly {
            config.defaultTransactionKind = .immediate
        }
        config.prepareDatabase { db in
            if !readonly {
                // Enable WAL mode for concurrent reads during writes
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                // Set synchronous mode to NORMAL for better performance
                try db.execute(sql: "PRAGMA synchronous=NORMAL")
            }
            // Retry for up to 5 seconds if the database is locked
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }

        // Create database pool (allows concurrent reads during writes in WAL mode)
        dbPool = try DatabasePool(path: path, configuration: config)

        #if os(iOS)
        // Deliver-while-locked: the NE must read/write after first unlock even when the
        // device is subsequently locked. Pin the data-protection class on the DB and its
        // -wal/-shm sidecar files to CompleteUntilFirstUserAuthentication.
        if !readonly {
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                try? fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path + suffix
                )
            }
        }
        #endif

        // Run migrations. SCHEMA FROZEN - see file header.
        var migrator = DatabaseMigrator()

        // v1: Initial schema
        migrator.registerMigration("v1_initial") { db in
            // Create conversations table
            try db.create(table: "conversations") { t in
                t.column("destination_hash", .blob).primaryKey().notNull()
                t.column("display_name", .text)
                t.column("last_message_timestamp", .double)
                t.column("last_message_preview", .text)
                t.column("unread_count", .integer).defaults(to: 0)
                t.column("is_unread", .integer).defaults(to: 0)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }

            // Create messages table
            try db.create(table: "messages") { t in
                t.column("message_id", .blob).primaryKey().notNull()
                t.column("conversation_hash", .blob).notNull()
                    .references("conversations", column: "destination_hash", onDelete: .cascade)
                t.column("destination_hash", .blob).notNull()
                t.column("source_hash", .blob).notNull()
                t.column("signature", .blob).notNull()
                t.column("timestamp", .double).notNull()
                t.column("title", .blob)
                t.column("content", .blob).notNull()
                t.column("fields", .blob)
                t.column("stamp", .blob)
                t.column("state", .integer).notNull()
                t.column("method", .integer).notNull()
                t.column("delivery_attempts", .integer).defaults(to: 0)
                t.column("progress", .double).defaults(to: 0.0)
                t.column("incoming", .integer).notNull()
                t.column("rssi", .double)
                t.column("snr", .double)
                t.column("q", .double)
                t.column("ratchet_id", .blob)
                t.column("packed_lxmf", .blob).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }

            // Create indexes for fast queries
            try db.create(index: "idx_messages_conversation_timestamp",
                         on: "messages",
                         columns: ["conversation_hash", "timestamp"])
            try db.create(index: "idx_messages_state",
                         on: "messages",
                         columns: ["state"])
            try db.create(index: "idx_messages_timestamp",
                         on: "messages",
                         columns: ["timestamp"])
            try db.create(index: "idx_conversations_last_timestamp",
                         on: "conversations",
                         columns: ["last_message_timestamp"])
        }

        // v2: Add is_favorite column to conversations
        migrator.registerMigration("v2_add_favorite") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "is_favorite", .integer).defaults(to: 0)
            }
        }

        // v3: Add icon appearance columns to conversations
        migrator.registerMigration("v3_add_icon_appearance") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "icon_name", .text)
                t.add(column: "icon_fg_color", .text)
                t.add(column: "icon_bg_color", .text)
            }
        }

        // v4: Add receiving_interface column to messages
        migrator.registerMigration("v4_add_receiving_interface") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "receiving_interface", .text)
            }
        }

        // v5: Add is_pinned column to conversations
        migrator.registerMigration("v5_add_pinned") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "is_pinned", .integer).defaults(to: 0)
            }
        }

        // v6: Add reply and reaction columns to messages
        migrator.registerMigration("v6_add_replies_reactions") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "reply_to_id", .text)
                t.add(column: "reactions_json", .text)
            }
            try db.create(index: "idx_messages_reply_to", on: "messages", columns: ["reply_to_id"])
        }

        // Only the writer runs migrations: GRDB's migrator issues an internal
        // `write {}` to atomically check/apply schema versions, which returns
        // SQLITE_READONLY (throws) on a read-only pool. Under Model B the writer (the
        // NE) owns the schema; the read-only app reader just opens the already-migrated
        // store, so migrating from it would throw at init before any read could happen.
        if !readonly {
            try migrator.migrate(dbPool)
        }
    }

    // MARK: - Message Operations

    /// Save a message row to the database, creating/updating its conversation.
    ///
    /// - Parameter row: MessageRow to save (built by MessageRepository from RNSAPI)
    /// - Throws: DatabaseError if save fails
    public func saveMessage(_ row: MessageRow) throws {
        try dbPool.write { db in
            // Update/create conversation FIRST (foreign key requires it)
            try self.updateConversationFor(row: row, in: db)
            // Save message (insert or replace)
            try row.save(db)
        }
    }

    /// Check if message exists.
    public func hasMessage(id: Data) throws -> Bool {
        try dbPool.read { db in
            try MessageRow
                .filter(Column("message_id") == id)
                .fetchCount(db) > 0
        }
    }

    /// Get all conversations ordered by last message timestamp descending.
    public func getConversations(limit: Int = 100, offset: Int = 0) throws -> [ConversationStoreRow] {
        try dbPool.read { db in
            try ConversationStoreRow
                .order(Column("last_message_timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Get single conversation by destination hash.
    public func getConversation(hash: Data) throws -> ConversationStoreRow? {
        try dbPool.read { db in
            try ConversationStoreRow
                .filter(Column("destination_hash") == hash)
                .fetchOne(db)
        }
    }

    /// Mark conversation as read.
    public func markConversationRead(hash: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET unread_count = 0, is_unread = 0, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Set the unread count for a conversation (e.g. mark as unread with count=1).
    public func setUnreadCount(hash: Data, count: Int) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET unread_count = ?, is_unread = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [count, count > 0 ? 1 : 0, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Delete conversation and all its messages (CASCADE foreign key).
    public func deleteConversation(hash: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM conversations WHERE destination_hash = ?",
                arguments: [hash]
            )
        }
    }

    /// Delete a single message by its ID hash.
    public func deleteMessage(id messageId: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE message_id = ?",
                arguments: [messageId]
            )
        }
    }

    /// Ensure a conversation exists for a destination.
    public func ensureConversation(hash: Data, displayName: String?) throws {
        try dbPool.write { db in
            if var conversation = try ConversationStoreRow
                .filter(Column("destination_hash") == hash)
                .fetchOne(db) {
                if conversation.displayName == nil, let displayName = displayName {
                    conversation.displayName = displayName
                    conversation.updatedAt = Date().timeIntervalSince1970
                    try conversation.update(db)
                }
            } else {
                let conversation = ConversationStoreRow(
                    destinationHash: hash,
                    displayName: displayName,
                    lastMessageTimestamp: Date().timeIntervalSince1970,
                    lastMessagePreview: nil,
                    unreadCount: 0
                )
                try conversation.insert(db)
            }
        }
    }

    /// Set pinned status for a conversation.
    public func setPinned(hash: Data, isPinned: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET is_pinned = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [isPinned ? 1 : 0, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Update display name for a conversation.
    public func updateDisplayName(hash: Data, displayName: String?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET display_name = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [displayName, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Set favorite status for a conversation.
    public func setFavorite(hash: Data, isFavorite: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET is_favorite = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [isFavorite ? 1 : 0, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Get raw message records for conversation (no wire unpacking).
    ///
    /// Returns lightweight `MessageRow` structs directly from database, avoiding
    /// the wire decode. Use this for UI display paths where only metadata is needed.
    public func getMessageRecords(forConversation hash: Data, limit: Int = 200, offset: Int = 0) throws -> [MessageRow] {
        try dbPool.read { db in
            try MessageRow
                .filter(Column("conversation_hash") == hash)
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// IDs of messages in the `.outbound` state or `.sent` small-packet messages
    /// awaiting a delivery proof. See the original `loadPendingOutbound` comment in
    /// LXMFSwift for why `.sent` is scoped to opportunistic/direct here.
    public func loadPendingOutboundIds() throws -> [Data] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT message_id FROM messages
                    WHERE (
                        state = ?
                        OR (
                            state = ?
                            AND (method = ? OR method = ?)
                        )
                    )
                    ORDER BY timestamp ASC
                    """,
                arguments: [
                    GRDBState.outbound.rawValue,
                    GRDBState.sent.rawValue,
                    GRDBDeliveryMethod.opportunistic.rawValue,
                    GRDBDeliveryMethod.direct.rawValue,
                ]
            ).map { $0["message_id"] as Data }
        }
    }

    /// IDs of messages in the `.failed` state.
    public func loadFailedOutboundIds() throws -> [Data] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT message_id FROM messages
                    WHERE state = ?
                    ORDER BY timestamp DESC
                    """,
                arguments: [GRDBState.failed.rawValue]
            ).map { $0["message_id"] as Data }
        }
    }

    // MARK: - Reply & Reaction Operations

    /// Update reply-to ID for a message.
    public func updateReplyToId(messageId: Data, replyToId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE messages SET reply_to_id = ?, updated_at = ? WHERE message_id = ?",
                arguments: [replyToId, Date().timeIntervalSince1970, messageId]
            )
        }
    }

    /// Update reactions JSON for a message.
    public func updateReactions(messageId: Data, reactionsJson: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE messages SET reactions_json = ?, updated_at = ? WHERE message_id = ?",
                arguments: [reactionsJson, Date().timeIntervalSince1970, messageId]
            )
        }
    }

    /// Get reactions JSON for a message.
    public func getReactionsJson(messageId: Data) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT reactions_json FROM messages WHERE message_id = ?",
                arguments: [messageId]
            )
        }
    }

    /// Get a single message record by ID (no wire unpacking).
    public func getMessageRecord(id: Data) throws -> MessageRow? {
        try dbPool.read { db in
            try MessageRow
                .filter(Column("message_id") == id)
                .fetchOne(db)
        }
    }

    // MARK: - Icon Appearance

    /// Update peer icon appearance for a conversation.
    public func updatePeerIcon(_ hash: Data, iconName: String, fgColor: String, bgColor: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET icon_name = ?, icon_fg_color = ?, icon_bg_color = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [iconName, fgColor, bgColor, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Get peer icon appearance for a conversation as the raw fields.
    ///
    /// Returns nil when no icon is set. The app maps the three fields to its own
    /// `RNSAPI.IconAppearance` (see MessageRepository.mapIcon) so the store does
    /// not depend on RNSAPI.
    public func getPeerIconFields(_ hash: Data) throws -> (name: String, fg: String, bg: String)? {
        try dbPool.read { db in
            guard let record = try ConversationStoreRow
                .filter(Column("destination_hash") == hash)
                .fetchOne(db) else { return nil }
            guard let name = record.iconName,
                  let fg = record.iconFgColor,
                  let bg = record.iconBgColor else { return nil }
            return (name, fg, bg)
        }
    }

    // MARK: - Private Helpers

    /// Update conversation record for a message row (internal helper).
    private func updateConversationFor(row: MessageRow, in db: Database) throws {
        let conversationHash = row.incoming ? row.sourceHash : row.destinationHash

        if var conversation = try ConversationStoreRow
            .filter(Column("destination_hash") == conversationHash)
            .fetchOne(db) {

            // Only update preview/timestamp if this message is newer (or equal).
            // This prevents an older outbound save from overwriting a newer
            // incoming message's preview when saves race.
            if row.timestamp >= conversation.lastMessageTimestamp {
                conversation.lastMessageTimestamp = row.timestamp
                conversation.updatedAt = Date().timeIntervalSince1970

                if !row.content.isEmpty,
                   let contentStr = String(data: row.content, encoding: .utf8),
                   !contentStr.isEmpty {
                    conversation.lastMessagePreview = String(contentStr.prefix(100))
                }
            }

            // Increment unread count if incoming (regardless of timestamp)
            if row.incoming {
                conversation.unreadCount += 1
                conversation.isUnread = 1
            }

            try conversation.update(db)
        } else {
            let preview = String(data: row.content, encoding: .utf8).map { String($0.prefix(100)) }

            let conversation = ConversationStoreRow(
                destinationHash: conversationHash,
                displayName: nil,
                lastMessageTimestamp: row.timestamp,
                lastMessagePreview: preview,
                unreadCount: row.incoming ? 1 : 0
            )

            try conversation.insert(db)
        }
    }
}
