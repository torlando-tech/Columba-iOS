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

/// Actor for thread-safe message database operations.
///
/// Wraps the GRDB-backed `LXMFSwift.LXMFDatabase` and exposes RNSAPI Compat
/// types so the existing ViewModels compile unchanged. All operations are
/// serialized through the underlying GRDB actor.
public actor MessageRepository {
    /// Posted after a conversation's unread count has been cleared in the
    /// canonical store. The chats list uses this to clear its in-memory badge
    /// while a conversation is open.
    public static let conversationReadNotification =
        Notification.Name("network.columba.conversationRead")

    /// Posted after an outbound message updates conversation activity. Inbound
    /// messages already use `IncomingMessageHandler.messageReceivedNotification`.
    public static let conversationActivityNotification =
        Notification.Name("network.columba.conversationActivity")

    public static let conversationHashUserInfoKey = "conversationHash"

    // MARK: - Properties

    /// The GRDB-backed canonical store written by the Swift / NE backend.
    private let database: LXMFSwift.LXMFDatabase
    /// Suspension-aware pool used only for atomic app-owned retry replacement.
    private let replacementPool: DatabasePool
    /// Retry hashes actively owned by this process. Recovery ignores these so
    /// reopening a conversation cannot race a send still awaiting its outcome.
    private var activeRetryHashes: Set<Data> = []

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
        config.observesSuspensionNotifications = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }
        self.replacementPool = try DatabasePool(path: grdbPath, configuration: config)
    }

    // MARK: - Conversation Operations

    /// Fetch all conversations, sorted by most recent message.
    public func fetchConversations(limit: Int = 100, offset: Int = 0) async throws -> [RNSAPI.ConversationRecord] {
        try await database.getConversations(limit: limit, offset: offset).map(Self.mapConversation)
    }

    /// Fetch a single conversation by destination hash.
    public func fetchConversation(_ conversationHash: Data) async throws -> RNSAPI.ConversationRecord? {
        try await database.getConversation(hash: conversationHash).map(Self.mapConversation)
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

    /// Delete conversation and all its messages (cascades via FK).
    public func deleteConversation(_ conversationHash: Data) async throws {
        try await database.deleteConversation(hash: conversationHash)
    }

    /// Delete a single message by its ID hash.
    public func deleteMessage(_ messageId: Data) async throws {
        try await database.deleteMessage(id: messageId)
    }

    /// Ensure a conversation exists for a destination.
    public func ensureConversation(_ conversationHash: Data, displayName: String?) async throws {
        try await database.ensureConversation(hash: conversationHash, displayName: displayName)
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

    /// Save a message (outbound from the app, or Python-path inbound).
    ///
    /// Bridges the RNSAPI `LXMessage` into the GRDB store via a synthetic
    /// `LXMFSwift.LXMessage` whose `packed` carries the MessagePack-encoded
    /// field map (NOT the signed LXMF wire — the app doesn't have it). The GRDB
    /// `MessageRecord` then stores that field map in its `packed_lxmf` column,
    /// which `mapRecord` passes back through as the RNSAPI `packedLxmf` field
    /// map so the chat UI's `LxmfFieldCodec.unpack` can recover attachments.
    public func saveMessage(_ message: RNSAPI.LXMessage) async throws {
        try await database.saveMessage(Self.mapToGRDBMessage(message))
        if !message.incoming {
            NotificationCenter.default.post(
                name: Self.conversationActivityNotification,
                object: nil,
                userInfo: [Self.conversationHashUserInfoKey: message.destinationHash]
            )
        }
    }

    /// Atomically rekey an app-owned optimistic or failed row to the canonical
    /// hash accepted by the network backend. Payload columns stay on the same
    /// row, so a crash cannot expose both a stale retry and a sent duplicate.
    public func replaceMessage(_ message: RNSAPI.LXMessage, replacing oldId: Data) async throws {
        try await replacementPool.write { db in
            try db.execute(
                sql: """
                    UPDATE messages
                    SET message_id = ?, state = ?, method = ?, timestamp = ?, updated_at = ?
                    WHERE message_id = ?
                    """,
                arguments: [
                    message.hash,
                    Self.mapStateToGRDB(message.state).rawValue,
                    Self.mapMethodToGRDB(message.method).rawValue,
                    message.timestamp,
                    Date().timeIntervalSince1970,
                    oldId,
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

    /// Stage one failed retry as `.sending` before network submission and mark
    /// it as actively owned by this process.
    public func stageRetry(_ message: RNSAPI.LXMessage, replacing oldId: Data) async throws {
        activeRetryHashes.insert(message.hash)
        do {
            try await replaceMessage(message, replacing: oldId)
        } catch {
            activeRetryHashes.remove(message.hash)
            throw error
        }
    }

    /// Release process ownership. If no definitive result replaced the staged
    /// row, expose it as failed instead of leaving it indefinitely pending.
    public func finishRetry(_ messageId: Data) async {
        activeRetryHashes.remove(messageId)
        try? await replacementPool.write { db in
            try db.execute(
                sql: """
                    UPDATE messages SET state = ?, updated_at = ?
                    WHERE message_id = ? AND state = ?
                    """,
                arguments: [
                    LXMFSwift.LXMessageState.failed.rawValue,
                    Date().timeIntervalSince1970,
                    messageId,
                    LXMFSwift.LXMessageState.sending.rawValue,
                ]
            )
        }
    }

    /// Recover retry rows left in `.sending` by termination before the backend
    /// returned a definitive result. They become user-visible failures rather
    /// than remaining indefinitely pending or being resent automatically.
    public func recoverInterruptedRetries(for destinationHash: Data) async throws -> Int {
        let active = activeRetryHashes
        return try await replacementPool.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT message_id FROM messages
                    WHERE destination_hash = ? AND incoming = 0 AND state = ?
                    """,
                arguments: [
                    destinationHash,
                    LXMFSwift.LXMessageState.sending.rawValue,
                ]
            )
            let interrupted = rows.compactMap { row -> Data? in
                let messageId: Data = row["message_id"]
                return active.contains(messageId) ? nil : messageId
            }
            for messageId in interrupted {
                try db.execute(
                    sql: "UPDATE messages SET state = ?, updated_at = ? WHERE message_id = ?",
                    arguments: [
                        LXMFSwift.LXMessageState.failed.rawValue,
                        Date().timeIntervalSince1970,
                        messageId,
                    ]
                )
            }
            return interrupted.count
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

    /// Update message delivery state.
    public func updateMessageState(id: Data, state: RNSAPI.LXMessageState) async throws {
        try await database.updateMessageState(id: id, state: Self.mapStateToGRDB(state))
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
    /// RNSAPI `.unknown` has no GRDB peer; default to `.opportunistic` (the
    /// canonical LXMF default delivery method).
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
