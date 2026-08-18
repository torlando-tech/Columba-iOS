//
//  MessageRepository.swift
//  ColumbaApp
//
//  Async wrapper for the LXMF message store, providing thread-safe message
//  and conversation access for SwiftUI ViewModels.
//
//  ── ARCHITECTURE (Track A0 — unify the canonical message store) ──────────────
//  This is the SOLE file in ColumbaApp that imports `LXMFSwift`. It opens the
//  GRDB-backed `LXMFSwift.LXMFDatabase` that the Swift / Network-Extension
//  backend writes (at `<configDir>/lxmf-swift.db`), so Swift/NE-delivered
//  messages show up in the existing SwiftUI layer WITHOUT changing the UI or
//  ViewModels — every public method below still takes/returns the RNSAPI
//  *Compat* types (RNSAPI.ConversationRecord / RNSAPI.MessageRecord /
//  RNSAPI.LXMessage / RNSAPI.IconAppearance / RNSAPI.LXMessageState /
//  RNSAPI.LXDeliveryMethod). The GRDB store's LXMFSwift types are adapted to
//  the RNSAPI types via the pure `static` mapping funcs at the bottom.
//
//  `import LXMFSwift` MUST NOT be added to AppServices.swift / ColumbaApp.swift
//  / MapView.swift or any other RNSAPI-dense file: LXMFSwift transitively
//  re-exports ReticulumSwift, whose type names (Identity, Destination, Link,
//  Packet, LXMRouter, …) collide with the RNSAPI Compat type names those files
//  use, producing an un-fixable ambiguity cascade. Keep the LXMFSwift import
//  walled off here.
//
//  A5 NOTE: this opens the GRDB store read-WRITE for now (the app's Python
//  inbound-persist path still writes through here). Once the NE owns all writes
//  (Track A5), switch to `LXMFSwift.LXMFDatabase(path:, readonly: true)`.
//

import Foundation
import RNSAPI
import LXMFSwift
import GRDB

public struct DraftRecord: Equatable, Sendable {
    public let conversationHash: Data
    public let content: String
    public let updatedAt: Date

    public init(conversationHash: Data, content: String, updatedAt: Date) {
        self.conversationHash = conversationHash
        self.content = content
        self.updatedAt = updatedAt
    }
}

/// Actor for thread-safe message database operations.
///
/// Wraps the GRDB-backed `LXMFSwift.LXMFDatabase` and exposes RNSAPI Compat
/// types so the existing ViewModels compile unchanged. All operations are
/// serialized through the underlying GRDB actor.
public actor MessageRepository {
    /// Keep set queries comfortably below SQLite's commonly configured bind
    /// variable limit while still avoiding one read per conversation.
    private static let conversationQueryChunkSize = 500

    /// Posted after a conversation's unread count has been cleared in the
    /// canonical store. The chats list uses this to clear its in-memory badge
    /// while a conversation is open.
    public static let conversationReadNotification =
        Notification.Name("network.columba.conversationRead")

    /// Posted after an outbound message updates conversation activity. Inbound
    /// messages already use `IncomingMessageHandler.messageReceivedNotification`.
    public static let conversationActivityNotification =
        Notification.Name("network.columba.conversationActivity")
    /// Posted after durable conversation metadata changes without a new message.
    public static let conversationMetadataChangedNotification =
        Notification.Name("network.columba.conversationMetadataChanged")
    /// Posted after an app-owned conversation draft has committed to storage.
    public static let draftChangedNotification =
        Notification.Name("network.columba.draftChanged")

    public static let conversationHashUserInfoKey = "conversationHash"
    public static let stagedRetryMarker = "columba-app-retry-staged-v1"
    public static let uncertainRetryMarker = "columba-app-retry-uncertain-v1"
    public static let optimisticOutboundMarker = "columba-app-outbound-optimistic-v1"

    public static func uncertainRetryMarker(canonicalHash: Data?) -> String {
        guard let canonicalHash else { return uncertainRetryMarker }
        return uncertainRetryMarker + ":" + canonicalHash.map { String(format: "%02x", $0) }.joined()
    }

    public static func isUncertainRetryMarker(_ marker: String?) -> Bool {
        marker?.hasPrefix(uncertainRetryMarker) == true
    }

    public static func canonicalHashFromUncertainRetryMarker(_ marker: String?) -> Data? {
        guard let marker,
              marker.hasPrefix(uncertainRetryMarker + ":") else { return nil }
        let hex = String(marker.dropFirst(uncertainRetryMarker.count + 1))
        guard hex.count == 64 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return data
    }

    // MARK: - Properties

    /// The GRDB-backed canonical store written by the Swift / NE backend.
    private let database: LXMFSwift.LXMFDatabase
    /// Suspension-aware pool used only for atomic app-owned retry replacement.
    private let replacementPool: DatabasePool


    // MARK: - Initialization

    /// Open the repository over the GRDB store at `grdbPath`.
    ///
    /// This is the SAME `<configDir>/lxmf-swift.db` the Swift backend's
    /// `LXMRouter` uses, so messages persisted by the Swift/NE path are visible
    /// here. Opened read-WRITE for now (A5 will switch to read-only once the NE
    /// owns writes).
    ///
    /// - Parameter grdbPath: Filesystem path to `lxmf-swift.db`.
    /// - Throws: rethrows `LXMFSwift.LXMFDatabase` initialization errors.
    public init(grdbPath: String) throws {
        self.database = try LXMFSwift.LXMFDatabase(path: grdbPath, readonly: false)
        var config = Configuration()
        config.defaultTransactionKind = .immediate
        config.foreignKeysEnabled = true
        config.observesSuspensionNotifications = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }
        self.replacementPool = try DatabasePool(path: grdbPath, configuration: config)
        try self.replacementPool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS columba_drafts (
                    conversation_hash BLOB PRIMARY KEY NOT NULL
                        REFERENCES conversations(destination_hash) ON DELETE CASCADE,
                    content TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL
                )
                """)
            // SQLite rowids can reuse the deleted highest value. Keep an app-owned,
            // AUTOINCREMENT insertion ledger so a propagation transaction cannot miss
            // a new row merely because its messages.rowid was reused. The trigger also
            // observes writes performed directly by the embedded Python router.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS columba_message_insertions (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    message_id BLOB NOT NULL UNIQUE
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS columba_track_message_insertion
                AFTER INSERT ON messages
                BEGIN
                    INSERT OR IGNORE INTO columba_message_insertions (message_id)
                    VALUES (NEW.message_id);
                END
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO columba_message_insertions (message_id)
                SELECT message_id FROM messages ORDER BY rowid ASC
                """)
        }
    }

    // MARK: - Conversation Operations

    /// Fetch all conversations, sorted by most recent message.
    public func fetchConversations(limit: Int = 100, offset: Int = 0) async throws -> [RNSAPI.ConversationRecord] {
        try await database.getConversations(limit: limit, offset: offset).map(Self.mapConversation)
    }

    /// Fetch conversations by their exact destination hashes without applying
    /// the paginated conversation-list limit.
    public func fetchConversations(for conversationHashes: [Data]) async throws -> [RNSAPI.ConversationRecord] {
        let hashes = Self.sortedUniqueHashes(conversationHashes)
        guard !hashes.isEmpty else { return [] }

        return try await replacementPool.read { db in
            var records: [LXMFSwift.ConversationRecord] = []
            for start in stride(from: 0, to: hashes.count, by: Self.conversationQueryChunkSize) {
                let end = min(start + Self.conversationQueryChunkSize, hashes.count)
                let chunk = Array(hashes[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                records += try LXMFSwift.ConversationRecord.fetchAll(
                    db,
                    sql: """
                        SELECT *
                        FROM conversations
                        WHERE destination_hash IN (\(placeholders))
                        ORDER BY destination_hash
                        """,
                    arguments: StatementArguments(chunk)
                )
            }
            return records.map(Self.mapConversation)
        }
    }

    /// Return the requested conversation hashes that have at least one row in
    /// the canonical messages table. Message preview text cannot provide this
    /// signal because attachment-only messages legitimately have empty content.
    public func fetchConversationHashesWithMessages(for conversationHashes: [Data]) async throws -> Set<Data> {
        let hashes = Self.sortedUniqueHashes(conversationHashes)
        guard !hashes.isEmpty else { return [] }

        return try await replacementPool.read { db in
            var result = Set<Data>()
            for start in stride(from: 0, to: hashes.count, by: Self.conversationQueryChunkSize) {
                let end = min(start + Self.conversationQueryChunkSize, hashes.count)
                let chunk = Array(hashes[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT conversation_hash
                        FROM messages
                        WHERE conversation_hash IN (\(placeholders))
                        """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    let conversationHash: Data = row["conversation_hash"]
                    result.insert(conversationHash)
                }
            }
            return result
        }
    }

    /// Fetch a single conversation by destination hash.
    public func fetchConversation(_ conversationHash: Data) async throws -> RNSAPI.ConversationRecord? {
        try await database.getConversation(hash: conversationHash).map(Self.mapConversation)
    }

    /// Return the durable unread-message total used for the application icon
    /// badge. This is independent of Notification Center history, whose delivered
    /// requests remain present after the icon badge itself is cleared.
    public func totalUnreadCount() async throws -> Int {
        let count = try await replacementPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(unread_count), 0) FROM conversations"
            ) ?? 0
        }
        return max(0, count)
    }

    private static func sortedUniqueHashes(_ hashes: [Data]) -> [Data] {
        Array(Set(hashes)).sorted { $0.lexicographicallyPrecedes($1) }
    }

    /// Mark conversation as read (reset unread count).
    public func markConversationRead(_ conversationHash: Data) async throws {
        try await database.markConversationRead(hash: conversationHash)
        NotificationCenter.default.post(
            name: Self.conversationReadNotification,
            object: nil,
            userInfo: [Self.conversationHashUserInfoKey: conversationHash]
        )
    }

    /// Set the unread count for a conversation (e.g. mark as unread with count=1).
    public func setUnreadCount(_ conversationHash: Data, count: Int) async throws {
        try await database.setUnreadCount(hash: conversationHash, count: count)
    }

    /// Delete a conversation, its messages, and its app-owned draft.
    public func deleteConversation(_ conversationHash: Data) async throws {
        try await deleteConversation(conversationHash, afterCanonicalDelete: nil)
    }

    /// Internal deterministic seam for coordinating work after the canonical
    /// deletion commits. Production passes no hook and does not suspend here.
    func deleteConversation(
        _ conversationHash: Data,
        afterCanonicalDelete: (@Sendable () async -> Void)?
    ) async throws {
        try await database.deleteConversation(hash: conversationHash)
        if let afterCanonicalDelete {
            await afterCanonicalDelete()
        }
        try clearOrphanedDraftAndNotify(for: conversationHash)
    }

    /// Delete a single message by its ID hash.
    public func deleteMessage(_ messageId: Data) async throws {
        try await database.deleteMessage(id: messageId)
    }

    /// Ensure a conversation exists for a destination.
    public func ensureConversation(_ conversationHash: Data, displayName: String?) async throws {
        try await database.ensureConversation(hash: conversationHash, displayName: displayName)
    }

    // MARK: - Draft Operations

    /// Atomically save a draft, or clear it when the content is only whitespace.
    /// Nonblank content is persisted exactly as provided.
    public func saveDraft(_ content: String, for conversationHash: Data) async throws {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try clearDraftAndNotify(for: conversationHash)
            return
        }

        // Keep the mutation and its notification in one actor-isolated
        // synchronous operation. This is a single atomic SQLite statement;
        // awaiting GRDB here would allow another draft mutation to commit before
        // this mutation posts its notification.
        try Self.writeDraftSynchronously(to: replacementPool) { db in
            try db.execute(
                sql: """
                    INSERT INTO columba_drafts (conversation_hash, content, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(conversation_hash) DO UPDATE SET
                        content = excluded.content,
                        updated_at = excluded.updated_at
                    """,
                arguments: [conversationHash, content, Date().timeIntervalSince1970]
            )
        }
        postDraftChanged(for: conversationHash)
    }

    /// Fetch the draft for one conversation.
    public func fetchDraft(for conversationHash: Data) async throws -> DraftRecord? {
        try await replacementPool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT conversation_hash, content, updated_at
                    FROM columba_drafts
                    WHERE conversation_hash = ?
                    """,
                arguments: [conversationHash]
            ).map(Self.mapDraft)
        }
    }

    /// Fetch all drafts keyed by conversation hash.
    public func fetchDrafts() async throws -> [Data: DraftRecord] {
        try await replacementPool.read { db in
            let drafts = try Row.fetchAll(
                db,
                sql: """
                    SELECT conversation_hash, content, updated_at
                    FROM columba_drafts
                    """
            ).map(Self.mapDraft)
            return Dictionary(uniqueKeysWithValues: drafts.map { ($0.conversationHash, $0) })
        }
    }

    /// Clear the draft for one conversation.
    public func clearDraft(for conversationHash: Data) async throws {
        try clearDraftAndNotify(for: conversationHash)
    }

    private func clearDraftAndNotify(for conversationHash: Data) throws {
        let deleted = try Self.writeDraftSynchronously(to: replacementPool) { db in
            try db.execute(
                sql: "DELETE FROM columba_drafts WHERE conversation_hash = ?",
                arguments: [conversationHash]
            )
            return db.changesCount > 0
        }
        if deleted {
            postDraftChanged(for: conversationHash)
        }
    }

    /// Delete only a draft that is still orphaned after canonical deletion.
    /// The parent check and deletion share one SQLite statement, so recreation
    /// and cleanup serialize in commit order across repository instances.
    private func clearOrphanedDraftAndNotify(for conversationHash: Data) throws {
        let deleted = try Self.writeDraftSynchronously(to: replacementPool) { db in
            try db.execute(
                sql: """
                    DELETE FROM columba_drafts
                    WHERE conversation_hash = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM conversations
                          WHERE destination_hash = ?
                      )
                    """,
                arguments: [conversationHash, conversationHash]
            )
            return db.changesCount > 0
        }
        if deleted {
            postDraftChanged(for: conversationHash)
        }
    }

    /// Resolves GRDB's sync/async overload in a synchronous context so draft
    /// mutations cannot suspend and re-enter this actor before notification.
    private static func writeDraftSynchronously<T>(
        to pool: DatabasePool,
        _ updates: (Database) throws -> T
    ) rethrows -> T {
        try pool.writeWithoutTransaction(updates)
    }

    private static func mapDraft(_ row: Row) -> DraftRecord {
        let conversationHash: Data = row["conversation_hash"]
        let content: String = row["content"]
        let updatedAt: Double = row["updated_at"]
        return DraftRecord(
            conversationHash: conversationHash,
            content: content,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private func postDraftChanged(for conversationHash: Data) {
        NotificationCenter.default.post(
            name: Self.draftChangedNotification,
            object: nil,
            userInfo: [Self.conversationHashUserInfoKey: conversationHash]
        )
    }

    /// Posted after persisted favorite/contact membership changes.
    public static let favoriteStatusChangedNotification =
        Notification.Name("network.columba.favoriteStatusChanged")

    /// Set favorite status for a conversation.
    public func setFavorite(_ conversationHash: Data, isFavorite: Bool) async throws {
        try await database.setFavorite(hash: conversationHash, isFavorite: isFavorite)
        NotificationCenter.default.post(
            name: Self.favoriteStatusChangedNotification,
            object: nil,
            userInfo: [Self.conversationHashUserInfoKey: conversationHash]
        )
    }

    /// Set pinned status for a conversation.
    public func setPinned(_ conversationHash: Data, isPinned: Bool) async throws {
        try await database.setPinned(hash: conversationHash, isPinned: isPinned)
    }

    /// Update display name for a conversation.
    public func updateDisplayName(_ conversationHash: Data, displayName: String?) async throws {
        try await database.updateDisplayName(hash: conversationHash, displayName: displayName)
    }

    /// Apply an announced peer name only while the durable row still contains
    /// an empty name or its generated hash placeholder. The predicate and write
    /// execute in one SQL statement so a concurrently saved custom nickname
    /// cannot be overwritten between a read and a later update.
    @discardableResult
    public func applyAnnouncedDisplayName(
        _ conversationHash: Data,
        displayName: String
    ) async throws -> Bool {
        guard !displayName.isEmpty else { return false }
        let generatedFallback = AppDataParser.generatedConversationName(
            destinationHash: conversationHash
        )
        let updated = try await replacementPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET display_name = ?, updated_at = ?
                    WHERE destination_hash = ?
                      AND (
                        display_name IS NULL
                        OR display_name = ''
                        OR display_name = ? COLLATE NOCASE
                      )
                    """,
                arguments: [
                    displayName,
                    Date().timeIntervalSince1970,
                    conversationHash,
                    generatedFallback,
                ]
            )
            return db.changesCount == 1
        }
        if updated {
            NotificationCenter.default.post(
                name: Self.conversationMetadataChangedNotification,
                object: nil,
                userInfo: [Self.conversationHashUserInfoKey: conversationHash]
            )
        }
        return updated
    }

    // MARK: - Icon Appearance

    /// Update peer icon appearance for a conversation.
    public func updatePeerIcon(_ hash: Data, icon: RNSAPI.IconAppearance) async throws {
        try await database.updatePeerIcon(hash, iconName: icon.iconName, fgColor: icon.foregroundColor, bgColor: icon.backgroundColor)
    }

    /// Get peer icon appearance for a conversation.
    public func getPeerIcon(_ hash: Data) async throws -> RNSAPI.IconAppearance? {
        try await database.getPeerIcon(hash).map(Self.mapIcon)
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
    public func getMessageRecord(id: Data) async throws -> RNSAPI.MessageRecord? {
        try await database.getMessageRecord(id: id).map(Self.mapRecord)
    }

    // MARK: - Message Operations

    /// Fetch messages for a conversation (LXMessage form).
    ///
    /// Rebuilt from the lightweight GRDB `MessageRecord` rows via `mapToLXMessage`,
    /// which recovers the field map whether the row stores a packed field map
    /// (app / Python path) or the signed LXMF wire (Swift / NE path). Ordered
    /// newest-first to match `getMessages`.
    public func fetchMessages(for conversationHash: Data, limit: Int = 50, offset: Int = 0) async throws -> [RNSAPI.LXMessage] {
        try await database.getMessageRecords(forConversation: conversationHash, limit: limit, offset: offset)
            .map(Self.mapToLXMessage)
    }

    /// Fetch raw message records for a conversation (no wire unpacking).
    ///
    /// This is the hot read path the chat UI uses. Returns RNSAPI
    /// `MessageRecord`s mapped directly from the GRDB rows.
    public func fetchMessageRecords(for conversationHash: Data, limit: Int = 50, offset: Int = 0) async throws -> [RNSAPI.MessageRecord] {
        try await database.getMessageRecords(forConversation: conversationHash, limit: limit, offset: offset)
            .map(Self.mapRecord)
    }

    /// Capture the current monotonic insertion boundary of the canonical message
    /// table. `messages.rowid` is unsuitable because SQLite can reuse the deleted
    /// highest rowid; the app-owned AUTOINCREMENT ledger cannot reuse sequences.
    public func captureMessageInsertionCursor() async throws -> Int64 {
        try await replacementPool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), 0) FROM columba_message_insertions"
            ) ?? 0
        }
    }

    /// Return inbound messages first inserted after a previously captured boundary.
    /// Existing message IDs re-delivered by a propagation node retain their ledger
    /// sequence and are excluded, so notifications describe new durable insertions.
    public func fetchIncomingMessagesInserted(after cursor: Int64) async throws -> [RNSAPI.LXMessage] {
        try await replacementPool.read { db in
            try LXMFSwift.MessageRecord.fetchAll(
                db,
                sql: """
                    SELECT messages.*
                    FROM columba_message_insertions
                    JOIN messages USING (message_id)
                    WHERE columba_message_insertions.sequence > ?
                      AND messages.incoming = 1
                    ORDER BY columba_message_insertions.sequence ASC
                    """,
                arguments: [cursor]
            ).map(Self.mapToLXMessage)
        }
    }

    /// Save a message (outbound from the app, or Python-path inbound).
    ///
    /// Bridges the RNSAPI `LXMessage` into the GRDB store via a synthetic
    /// `LXMFSwift.LXMessage` whose `packed` carries the MessagePack-encoded
    /// field map (NOT the signed LXMF wire — the app doesn't have it). The GRDB
    /// `MessageRecord` then stores that field map in its `packed_lxmf` column,
    /// which `mapRecord` passes back through as the RNSAPI `packedLxmf` field
    /// map so the chat UI's `LxmfFieldCodec.unpack` can recover attachments.
    public func saveMessage(_ message: RNSAPI.LXMessage) async throws {
        let mapped = Self.mapToGRDBMessage(message)
        if message.method == .unknown {
            // LXMFSwift's enum cannot represent unknown, but its persisted record
            // stores a raw byte. Build the record from the mapped message, replace
            // only that byte with an out-of-domain sentinel, and save the
            // conversation + message in one immediate transaction. This prevents
            // readers or competing writers from observing a temporary
            // Opportunistic value.
            var record = try LXMFSwift.MessageRecord(from: mapped)
            record.method = 0
            try await replacementPool.write { db in
                try Self.updateConversation(for: mapped, in: db)
                try record.save(db)
            }
        } else {
            try await database.saveMessage(mapped)
        }
        if !message.incoming {
            NotificationCenter.default.post(
                name: Self.conversationActivityNotification,
                object: nil,
                userInfo: [Self.conversationHashUserInfoKey: message.destinationHash]
            )
        }
    }

    /// Mirror LXMFSwift's conversation update inside the app-owned transaction
    /// used for raw method values that its enum cannot represent.
    private static func updateConversation(
        for message: LXMFSwift.LXMessage,
        in db: Database
    ) throws {
        let conversationHash = message.incoming ? message.sourceHash : message.destinationHash
        if var conversation = try LXMFSwift.ConversationRecord
            .filter(Column("destination_hash") == conversationHash)
            .fetchOne(db) {
            if message.timestamp >= conversation.lastMessageTimestamp {
                conversation.lastMessageTimestamp = message.timestamp
                conversation.updatedAt = Date().timeIntervalSince1970
                if !message.content.isEmpty,
                   let content = String(data: message.content, encoding: .utf8),
                   !content.isEmpty {
                    conversation.lastMessagePreview = String(content.prefix(100))
                }
            }
            if message.incoming {
                conversation.unreadCount += 1
                conversation.isUnread = 1
            }
            try conversation.update(db)
        } else {
            let preview = String(data: message.content, encoding: .utf8).map {
                String($0.prefix(100))
            }
            let conversation = LXMFSwift.ConversationRecord(
                destinationHash: conversationHash,
                displayName: nil,
                lastMessageTimestamp: message.timestamp,
                lastMessagePreview: preview,
                unreadCount: message.incoming ? 1 : 0
            )
            try conversation.insert(db)
        }
    }

    /// Atomically rekey an app-owned optimistic or failed row to the canonical
    /// hash accepted by the network backend. Payload columns stay on the same
    /// row, so a crash cannot expose both a stale retry and a sent duplicate.
    public func replaceMessage(_ message: RNSAPI.LXMessage, replacing oldId: Data) async throws {
        let marker = message.receivingInterface == Self.optimisticOutboundMarker
            ? Self.optimisticOutboundMarker
            : nil
        try await replaceMessageRecord(message, replacing: oldId, retryMarker: marker)
    }

    /// Stage one failed retry as app-owned `.sending` before network submission.
    /// The compare-and-set prevents concurrent taps from owning the same row.
    public func stageRetry(_ message: RNSAPI.LXMessage, replacing oldId: Data) async throws {
        try await replacementPool.write { db in
            try db.execute(
                sql: """
                    UPDATE messages
                    SET message_id = ?, state = ?, method = ?, timestamp = ?,
                        receiving_interface = ?, updated_at = ?
                    WHERE message_id = ? AND incoming = 0 AND state = ?
                      AND (receiving_interface IS NULL OR receiving_interface LIKE ?
                           OR receiving_interface = ?)
                    """,
                arguments: [
                    message.hash,
                    Self.mapStateToGRDB(message.state).rawValue,
                    Self.mapMethodToGRDB(message.method).rawValue,
                    message.timestamp,
                    Self.stagedRetryMarker,
                    Date().timeIntervalSince1970,
                    oldId,
                    LXMFSwift.LXMessageState.failed.rawValue,
                    Self.uncertainRetryMarker + "%",
                    Self.optimisticOutboundMarker,
                ]
            )
            guard db.changesCount == 1 else {
                throw MessageRepositoryError.replacementSourceMissing
            }
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET last_message_timestamp = ?, updated_at = ?
                    WHERE destination_hash = ? AND last_message_timestamp <= ?
                    """,
                arguments: [
                    message.timestamp,
                    Date().timeIntervalSince1970,
                    message.destinationHash,
                    message.timestamp,
                ]
            )
        }
        NotificationCenter.default.post(
            name: Self.conversationActivityNotification,
            object: nil,
            userInfo: [Self.conversationHashUserInfoKey: message.destinationHash]
        )
    }

    /// Return an interrupted staged retry to a durable, explicitly uncertain
    /// failed state without deleting its only database row.
    public func recoverStagedRetry(_ messageId: Data, canonicalHash: Data? = nil) async throws {
        try await replacementPool.write { db in
            try db.execute(
                sql: """
                    UPDATE messages
                    SET state = ?, receiving_interface = ?, updated_at = ?
                    WHERE message_id = ? AND incoming = 0
                      AND receiving_interface = ?
                    """,
                arguments: [
                    LXMFSwift.LXMessageState.failed.rawValue,
                    Self.uncertainRetryMarker(canonicalHash: canonicalHash),
                    Date().timeIntervalSince1970,
                    messageId,
                    Self.stagedRetryMarker,
                ]
            )
            guard db.changesCount == 1 else {
                throw MessageRepositoryError.replacementSourceMissing
            }
        }
    }

    private func replaceMessageRecord(
        _ message: RNSAPI.LXMessage,
        replacing oldId: Data,
        retryMarker: String?
    ) async throws {
        try await replacementPool.write { db in
            try db.execute(
                sql: """
                    UPDATE messages
                    SET message_id = ?, state = ?, method = ?, timestamp = ?,
                        receiving_interface = ?, updated_at = ?
                    WHERE message_id = ?
                    """,
                arguments: StatementArguments([
                    message.hash,
                    Self.mapStateToGRDB(message.state).rawValue,
                    Self.mapMethodToGRDB(message.method).rawValue,
                    message.timestamp,
                    retryMarker,
                    Date().timeIntervalSince1970,
                    oldId,
                ] as [DatabaseValueConvertible?])
            )
            guard db.changesCount == 1 else {
                throw MessageRepositoryError.replacementSourceMissing
            }
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET last_message_timestamp = ?, updated_at = ?
                    WHERE destination_hash = ? AND last_message_timestamp <= ?
                    """,
                arguments: [
                    message.timestamp,
                    Date().timeIntervalSince1970,
                    message.destinationHash,
                    message.timestamp,
                ]
            )
        }

        NotificationCenter.default.post(
            name: Self.conversationActivityNotification,
            object: nil,
            userInfo: [Self.conversationHashUserInfoKey: message.destinationHash]
        )
    }

    /// Recover only app-owned retries left staged by a prior process. The
    /// uncertainty marker remains durable until a later retry or deletion, so
    /// a transient UI-load failure cannot erase the warning.
    public func recoverInterruptedRetries() async throws -> Int {
        try await replacementPool.write { db in
            try db.execute(
                sql: """
                    UPDATE messages
                    SET state = ?, receiving_interface = ?, updated_at = ?
                    WHERE incoming = 0 AND state = ? AND receiving_interface = ?
                    """,
                arguments: [
                    LXMFSwift.LXMessageState.failed.rawValue,
                    Self.uncertainRetryMarker,
                    Date().timeIntervalSince1970,
                    LXMFSwift.LXMessageState.sending.rawValue,
                    Self.stagedRetryMarker,
                ]
            )
            return db.changesCount
        }
    }

    /// Check the entire conversation, independently of message pagination, for
    /// a recovered retry whose delivery outcome remains unknown.
    public func hasUncertainRetry(for destinationHash: Data) async throws -> Bool {
        try await replacementPool.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM messages
                    WHERE destination_hash = ? AND incoming = 0 AND state = ?
                      AND receiving_interface LIKE ?
                    """,
                arguments: [
                    destinationHash,
                    LXMFSwift.LXMessageState.failed.rawValue,
                    Self.uncertainRetryMarker + "%",
                ]
            ) ?? 0
            return count > 0
        }
    }

    /// Get message by ID (LXMessage form), rebuilt from the GRDB record.
    public func getMessage(id: Data) async throws -> RNSAPI.LXMessage? {
        try await database.getMessageRecord(id: id).map(Self.mapToLXMessage)
    }

    /// Check if message exists.
    public func hasMessage(id: Data) async throws -> Bool {
        try await database.hasMessage(id: id)
    }

    /// Update message delivery state and optional effective transport without
    /// allowing stale evidence to downgrade authoritative recipient delivery.
    @discardableResult
    public func updateMessageState(
        id: Data,
        state: RNSAPI.LXMessageState,
        method: RNSAPI.LXDeliveryMethod? = nil
    ) async throws -> Bool {
        try await replacementPool.write { db in
            let incomingState = Int(Self.mapStateToGRDB(state).rawValue)
            let existingState = try Int.fetchOne(
                db,
                sql: "SELECT state FROM messages WHERE message_id = ?",
                arguments: [id]
            )
            let persistedState = Self.monotonicDeliveryState(
                existing: existingState,
                incoming: incomingState
            )
            let persistedMethod = persistedState == incomingState
                ? method.map { Self.mapMethodToGRDB($0).rawValue }
                : nil
            try db.execute(
                sql: """
                    UPDATE messages
                    SET state = ?, method = COALESCE(?, method), updated_at = ?
                    WHERE message_id = ?
                    """,
                arguments: [
                    persistedState,
                    persistedMethod,
                    Date().timeIntervalSince1970,
                    id,
                ]
            )
            return db.changesCount > 0
        }
    }

    /// Persist an authoritative backend delivery proof. If canonical message
    /// persistence previously failed during a retry, atomically resolve the
    /// durable storage-key row through its canonical uncertainty marker and
    /// rekey it to the wire hash. This path works without an open chat view.
    static func monotonicDeliveryState(existing: Int?, incoming: Int) -> Int {
        guard let existing else { return incoming }
        let sending = Int(LXMFSwift.LXMessageState.sending.rawValue)
        let sent = Int(LXMFSwift.LXMessageState.sent.rawValue)
        let delivered = Int(LXMFSwift.LXMessageState.delivered.rawValue)
        let failed = Int(LXMFSwift.LXMessageState.failed.rawValue)

        if existing == delivered || incoming == delivered { return delivered }

        // A transport or relay acceptance cannot be revoked by a delayed
        // retry-start/failure callback. Conversely, a terminal failure can be
        // superseded by later positive proof, but not by stale retry admission.
        if existing == sent && (incoming == sending || incoming == failed) {
            return sent
        }
        if existing == failed && incoming == sending {
            return failed
        }
        return incoming
    }

    @discardableResult
    public func applyDeliveryProof(
        canonicalHash: Data,
        state: RNSAPI.LXMessageState,
        method: RNSAPI.LXDeliveryMethod? = nil
    ) async throws -> Bool {
        try await replacementPool.write { db in
            let incomingState = Int(Self.mapStateToGRDB(state).rawValue)
            let mappedMethod = method.map { Self.mapMethodToGRDB($0).rawValue }
            let now = Date().timeIntervalSince1970
            let existingCanonicalState = try Int.fetchOne(
                db,
                sql: "SELECT state FROM messages WHERE message_id = ?",
                arguments: [canonicalHash]
            )
            let canonicalState = Self.monotonicDeliveryState(
                existing: existingCanonicalState,
                incoming: incomingState
            )
            let canonicalMethod = canonicalState == incomingState ? mappedMethod : nil
            try db.execute(
                sql: """
                    UPDATE messages
                    SET state = ?, method = COALESCE(?, method), updated_at = ?
                    WHERE message_id = ?
                    """,
                arguments: [canonicalState, canonicalMethod, now, canonicalHash]
            )
            if db.changesCount == 1 {
                try db.execute(
                    sql: """
                        DELETE FROM messages
                        WHERE message_id != ? AND incoming = 0
                          AND receiving_interface = ?
                        """,
                    arguments: [
                        canonicalHash,
                        Self.uncertainRetryMarker(canonicalHash: canonicalHash),
                    ]
                )
                return true
            }

            let uncertaintyMarker = Self.uncertainRetryMarker(canonicalHash: canonicalHash)
            let existingAliasState = try Int.fetchOne(
                db,
                sql: "SELECT state FROM messages WHERE incoming = 0 AND receiving_interface = ?",
                arguments: [uncertaintyMarker]
            )
            let aliasState = Self.monotonicDeliveryState(
                existing: existingAliasState,
                incoming: incomingState
            )
            let aliasMethod = aliasState == incomingState ? mappedMethod : nil
            try db.execute(
                sql: """
                    UPDATE messages
                    SET message_id = ?, state = ?, method = COALESCE(?, method),
                        receiving_interface = NULL,
                        updated_at = ?
                    WHERE incoming = 0 AND receiving_interface = ?
                    """,
                arguments: [
                    canonicalHash,
                    aliasState,
                    aliasMethod,
                    now,
                    uncertaintyMarker,
                ]
            )
            return db.changesCount == 1
        }
    }

    /// Load pending outbound messages (state == .outbound).
    public func loadPendingOutbound() async throws -> [RNSAPI.LXMessage] {
        try await loadOutbound(matching: .outbound)
    }

    /// Load failed outbound messages (state == .failed).
    public func loadFailedOutbound() async throws -> [RNSAPI.LXMessage] {
        try await loadOutbound(matching: .failed)
    }

    /// Shared helper: load outbound messages in a given GRDB state by walking
    /// the GRDB `loadPendingOutbound` / `loadFailedOutbound` record IDs and
    /// re-fetching their raw records, so the result maps through the field-map
    /// bridge rather than the wire-unpack path.
    private func loadOutbound(matching state: LXMFSwift.LXMessageState) async throws -> [RNSAPI.LXMessage] {
        // The GRDB store only exposes outbound/failed via LXMessage-returning
        // methods (which wire-unpack). Those would throw on app-written rows
        // whose `packed_lxmf` is a field map, not real wire — so instead fetch
        // the matching records by ID through `getMessageRecord` and bridge.
        let messages: [LXMFSwift.LXMessage]
        switch state {
        case .outbound: messages = (try? await database.loadPendingOutbound()) ?? []
        case .failed:   messages = (try? await database.loadFailedOutbound()) ?? []
        default:        messages = []
        }
        // For each (successfully-unpacked) message, re-fetch its lightweight
        // record so the RNSAPI mapping is uniform with the read paths above.
        var out: [RNSAPI.LXMessage] = []
        for m in messages {
            if let rec = try await database.getMessageRecord(id: m.hash) {
                out.append(Self.mapToLXMessage(rec))
            }
        }
        return out
    }
}

enum MessageRepositoryError: Error {
    case replacementSourceMissing
}

// MARK: - Adapters (LXMFSwift <- -> RNSAPI)
//
// Pure `static` functions so the round-trip mapping can be unit-tested
// directly (see MessageRepositoryAdapterTests). Direction in the name reflects
// the conversion direction: `map*` = GRDB → RNSAPI; `mapTo*` = RNSAPI → GRDB.

extension MessageRepository {

    // MARK: Conversation

    /// GRDB `ConversationRecord` → RNSAPI `ConversationRecord`.
    static func mapConversation(_ c: LXMFSwift.ConversationRecord) -> RNSAPI.ConversationRecord {
        RNSAPI.ConversationRecord(
            hash: c.destinationHash,
            displayName: c.displayName ?? "",
            isFavorite: c.isFavorite,
            isPinned: c.isPinned,
            lastMessageAt: Date(timeIntervalSince1970: c.lastMessageTimestamp),
            lastMessage: c.lastMessagePreview,
            unreadCount: c.unreadCount,
            iconName: c.iconName,
            iconFgColor: c.iconFgColor,
            iconBgColor: c.iconBgColor
        )
    }

    // MARK: Icon

    /// GRDB `IconAppearance` → RNSAPI `IconAppearance`.
    static func mapIcon(_ i: LXMFSwift.IconAppearance) -> RNSAPI.IconAppearance {
        RNSAPI.IconAppearance(
            iconName: i.iconName,
            foregroundColor: i.foregroundColor,
            backgroundColor: i.backgroundColor
        )
    }

    // MARK: Message record

    /// Recover an LXMF field map from a GRDB row's `packed_lxmf`, regardless of
    /// whether that column holds a MessagePack **field map** (app / Python-path
    /// rows, written via `LxmfFieldCodec.pack`) or the signed LXMF **wire**
    /// (rows the Swift / Network-Extension backend persists — `LXMRouter` stores
    /// `LXMessage.packed`, the on-wire bytes, into `packed_lxmf`).
    ///
    /// ── Discriminator (wire vs field map) — order is load-bearing ──
    /// We attempt the WIRE decode *first* (`LXMessage.unpackFromBytes`) and only
    /// fall back to the field-map codec. This direction is deliberate:
    ///
    ///   • `unpackFromBytes` is strict: it requires `count > 96` (dest 16 + src
    ///     16 + sig 64) AND the trailing msgpack to be an *array* whose [0] is a
    ///     numeric timestamp and [1]/[2] are binary/string title+content. A
    ///     field map is a top-level msgpack *map*; small ones (text-only =
    ///     empty `Data()`, or just an icon/reply) fail the size guard, and a
    ///     large one (image/file ≥ 96 B) has its byte-tail-past-96 fed to the
    ///     msgpack parser, which essentially never yields a 4+ element array
    ///     with those exact element types. So a field map is not mistaken for
    ///     wire.
    ///   • The reverse order would NOT be safe: `LxmfFieldCodec.unpack` reads a
    ///     single top-level msgpack value from byte 0 and *ignores trailing
    ///     bytes* (see `MsgPack.unpack`). On wire, byte 0 is an arbitrary
    ///     destination-hash byte; whenever it lands in the fixmap range
    ///     (0x80–0x8f, ~1/16 of rows) `unpack` happily decodes a bogus map from
    ///     the following hash/sig bytes — so a wire row would be misread as a
    ///     field map and its attachments dropped.
    ///
    /// Signature is intentionally NOT re-validated here: `unpackFromBytes` only
    /// verifies the signature when given a `sourceIdentity` (we pass `nil`), and
    /// `LXMRouter` already validated it at receive time — at render time we only
    /// need to *extract* fields. With `nil` identity, `unpackFromBytes` still
    /// fully populates `.fields` (it just marks the message source-unverified).
    static func recoverFields(from packedLxmf: Data) -> [UInt8: Any]? {
        // WIRE first (strict). A wire row carries its fields inside the signed
        // payload; extract them without re-validating the signature.
        if let wire = try? LXMFSwift.LXMessage.unpackFromBytes(packedLxmf, sourceIdentity: nil),
           let fields = wire.fields, !fields.isEmpty {
            return fields
        }
        // Otherwise treat the bytes as a MessagePack field map (app / Python
        // path), or wire with no fields → nil.
        return LxmfFieldCodec.unpack(packedLxmf)
    }

    /// Normalize a row's `packed_lxmf` to the MessagePack **field map** the chat
    /// UI consumes (`LxmfFieldCodec.unpack` in `MessageBubble`/`Message(from:)`).
    /// Wire rows are unpacked and re-packed as a field map; field-map rows (and
    /// empty / no-field bytes) are already in the right shape and pass through
    /// untouched, so only the wire branch does extra work.
    static func normalizedFieldMap(_ packedLxmf: Data) -> Data {
        // WIRE first, with the SAME strict discriminator as `recoverFields`:
        // we must NOT gate on `LxmfFieldCodec.unpack(...) != nil` here, because
        // that codec ignores trailing bytes and can spuriously decode a bogus
        // map from a wire row whose leading hash byte is a fixmap marker
        // (~1/16) — which would leave the wire bytes un-normalized and the
        // attachments unrendered. Re-pack only genuine wire-with-fields.
        if let wire = try? LXMFSwift.LXMessage.unpackFromBytes(packedLxmf, sourceIdentity: nil),
           let fields = wire.fields, !fields.isEmpty {
            return LxmfFieldCodec.pack(fields)
        }
        // Field map (app / Python path), empty, or wire-without-fields: already
        // the shape the UI handles — hand it back verbatim.
        return packedLxmf
    }

    /// GRDB `MessageRecord` → RNSAPI `MessageRecord`.
    ///
    /// `packedLxmf` is normalized to a MessagePack field map: app / Python-path
    /// rows already store one (passed through verbatim), while Swift / NE rows
    /// store the signed LXMF wire — those are unpacked and re-packed as a field
    /// map so the chat UI's `LxmfFieldCodec.unpack(record.packedLxmf)` recovers
    /// their attachments/icons too. See `recoverFields` / `normalizedFieldMap`.
    static func mapRecord(_ r: LXMFSwift.MessageRecord) -> RNSAPI.MessageRecord {
        RNSAPI.MessageRecord(
            id: r.messageId,
            conversationHash: r.conversationHash,
            content: r.content,
            timestamp: r.timestamp,
            direction: r.incoming ? .inbound : .outbound,
            state: mapState(r.state).rawValue,
            messageId: r.messageId,
            sourceHash: r.sourceHash,
            method: mapMethod(r.method).rawValue,
            rssi: r.rssi,
            snr: r.snr,
            receivingInterface: r.receivingInterface,
            replyToId: r.replyToId,
            reactionsJson: r.reactionsJson,
            packedLxmf: normalizedFieldMap(r.packedLxmf)
        )
    }

    /// GRDB `MessageRecord` → RNSAPI `LXMessage` (via the field-map bridge).
    static func mapToLXMessage(_ r: LXMFSwift.MessageRecord) -> RNSAPI.LXMessage {
        // Recover fields whether `packed_lxmf` is a field map or the LXMF wire,
        // so attachment/icon fields survive for Swift/NE-delivered rows too.
        let fields = recoverFields(from: r.packedLxmf)
        let msg = RNSAPI.LXMessage(
            destinationHash: r.destinationHash,
            sourceIdentity: nil,
            content: r.content,
            title: r.title,
            fields: fields,
            desiredMethod: mapMethod(r.method)
        )
        msg.sourceHash = r.sourceHash
        msg.hash = r.messageId
        msg.timestamp = r.timestamp
        msg.incoming = r.incoming
        msg.state = mapState(r.state)
        msg.method = mapMethod(r.method)
        msg.rssi = r.rssi
        msg.snr = r.snr
        msg.q = r.q
        msg.receivingInterface = r.receivingInterface
        // Keep `packed` as the field map (matching `msg.fields` and the A0
        // bridge contract): wire rows are normalized so this stays coherent.
        msg.packed = normalizedFieldMap(r.packedLxmf)
        return msg
    }

    /// RNSAPI `LXMessage` → GRDB `LXMessage` (for the save path).
    ///
    /// Uses the GRDB no-identity outbound init, then carries the field map in
    /// `packed` so `MessageRecord(from:)` persists it into `packed_lxmf`. The
    /// conversation key (incoming → sourceHash, outbound → destinationHash) is
    /// preserved by setting `incoming` to match.
    static func mapToGRDBMessage(_ m: RNSAPI.LXMessage) -> LXMFSwift.LXMessage {
        var out = LXMFSwift.LXMessage(
            destinationHash: m.destinationHash,
            sourceHash: m.sourceHash,
            content: m.content,
            title: m.title,
            timestamp: m.timestamp,
            state: mapStateToGRDB(m.state),
            incoming: m.incoming
        )
        out.hash = m.hash
        out.method = mapMethodToGRDB(m.method)
        out.rssi = m.rssi
        out.snr = m.snr
        out.q = m.q
        out.receivingInterface = m.receivingInterface
        out.fields = m.fields
        // Carry the MessagePack field map as `packed` so `MessageRecord(from:)`
        // (which requires non-nil `packed` and copies it to `packed_lxmf`)
        // succeeds without the signed LXMF wire. Empty Data when no fields,
        // matching `LxmfFieldCodec.pack`'s empty-map convention.
        out.packed = (m.fields?.isEmpty == false) ? LxmfFieldCodec.pack(m.fields!) : Data()
        return out
    }

    // MARK: State

    /// GRDB `LXMessageState` (UInt8) → RNSAPI `LXMessageState` (semantic).
    ///
    /// GRDB has `generating`/`rejected`/`cancelled` with no RNSAPI peer:
    /// `generating` → `.draft`; `rejected`/`cancelled` → `.failed`.
    static func mapState(_ s: LXMFSwift.LXMessageState) -> RNSAPI.LXMessageState {
        switch s {
        case .generating: return .draft
        case .outbound:   return .outbound
        case .sending:    return .sending
        case .sent:       return .sent
        case .delivered:  return .delivered
        case .rejected:   return .failed
        case .cancelled:  return .failed
        case .failed:     return .failed
        }
    }

    /// Map a raw GRDB state byte → RNSAPI `LXMessageState`. Unknown bytes fall
    /// back to `.sent` (matches the chat UI's `default` arm in
    /// `Message(from:)`).
    static func mapState(_ raw: UInt8) -> RNSAPI.LXMessageState {
        guard let s = LXMFSwift.LXMessageState(rawValue: raw) else { return .sent }
        return mapState(s)
    }

    /// RNSAPI `LXMessageState` → GRDB `LXMessageState`.
    ///
    /// RNSAPI `.received` (inbound) maps to GRDB `.delivered` (the GRDB store
    /// has no inbound-specific state; `incoming` carries that distinction).
    static func mapStateToGRDB(_ s: RNSAPI.LXMessageState) -> LXMFSwift.LXMessageState {
        switch s {
        case .draft:     return .generating
        case .outbound:  return .outbound
        case .sending:   return .sending
        case .sent:      return .sent
        case .delivered: return .delivered
        case .failed:    return .failed
        case .received:  return .delivered
        }
    }

    // MARK: Method

    /// GRDB `LXDeliveryMethod` (UInt8) → RNSAPI `LXDeliveryMethod`.
    static func mapMethod(_ m: LXMFSwift.LXDeliveryMethod) -> RNSAPI.LXDeliveryMethod {
        switch m {
        case .opportunistic: return .opportunistic
        case .direct:        return .direct
        case .propagated:    return .propagated
        case .paper:         return .paper
        }
    }

    /// Map a raw GRDB method byte → RNSAPI `LXDeliveryMethod`. Unknown bytes
    /// fall back to `.unknown`.
    static func mapMethod(_ raw: UInt8) -> RNSAPI.LXDeliveryMethod {
        guard let m = LXMFSwift.LXDeliveryMethod(rawValue: raw) else { return .unknown }
        return mapMethod(m)
    }

    /// RNSAPI `LXDeliveryMethod` → GRDB `LXDeliveryMethod`.
    ///
    /// RNSAPI `.unknown` has no GRDB enum peer. `saveMessage` replaces the
    /// mapped record's temporary value with raw sentinel zero before inserting
    /// it in the same transaction, so reads map it back to `.unknown`.
    static func mapMethodToGRDB(_ m: RNSAPI.LXDeliveryMethod) -> LXMFSwift.LXDeliveryMethod {
        switch m {
        case .opportunistic: return .opportunistic
        case .direct:        return .direct
        case .propagated:    return .propagated
        case .paper:         return .paper
        case .unknown:       return .opportunistic
        }
    }
}
