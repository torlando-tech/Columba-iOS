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

/// Actor for thread-safe message database operations.
///
/// Wraps the GRDB-backed `LXMFSwift.LXMFDatabase` and exposes RNSAPI Compat
/// types so the existing ViewModels compile unchanged. All operations are
/// serialized through the underlying GRDB actor.
public actor MessageRepository {
    // MARK: - Properties

    /// The GRDB-backed canonical store written by the Swift / NE backend.
    private let database: LXMFSwift.LXMFDatabase

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

    /// Set favorite status for a conversation.
    public func setFavorite(_ conversationHash: Data, isFavorite: Bool) async throws {
        try await database.setFavorite(hash: conversationHash, isFavorite: isFavorite)
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
    /// Rebuilt from the lightweight GRDB `MessageRecord` rows via the field-map
    /// bridge rather than unpacking the LXMF wire (the app lacks the signed wire
    /// bytes). Ordered newest-first to match `getMessages`.
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

    /// GRDB `MessageRecord` → RNSAPI `MessageRecord`.
    ///
    /// `packedLxmf` is passed through verbatim: for app-written rows it is the
    /// MessagePack field map (what the chat UI's `LxmfFieldCodec.unpack`
    /// expects). NE-written rows currently store the full LXMF wire there — see
    /// the file/A0 note; attachment extraction on those rows is a known
    /// follow-up.
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
            packedLxmf: r.packedLxmf
        )
    }

    /// GRDB `MessageRecord` → RNSAPI `LXMessage` (via the field-map bridge).
    static func mapToLXMessage(_ r: LXMFSwift.MessageRecord) -> RNSAPI.LXMessage {
        let fields = LxmfFieldCodec.unpack(r.packedLxmf)
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
        msg.packed = r.packedLxmf
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
