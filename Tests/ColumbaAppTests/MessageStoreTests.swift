//
//  MessageStoreTests.swift
//  ColumbaAppTests
//
//  Unit + integration coverage for the app-owned `MessageStore` (the GRDB store
//  lifted out of LXMFSwift so the store no longer depends on the wire library).
//
//  Scope:
//   - Schema freeze: the store's `messages` / `conversations` columns are
//     byte-for-byte the contract the Network-Extension's embedded Python node
//     writes into (rns_bridge.py `_write_inbound_to_grdb`). Any drift here breaks
//     cross-process delivery, so we assert the exact column set.
//   - State/method vocabulary: the persisted raw bytes round-trip through the
//     mapper exactly as the frozen `GRDBState` / `GRDBDeliveryMethod` define.
//   - Store round-trip: save a row, read it back, the conversation is upserted
//     with the correct preview/unread accounting.
//   - Cross-process: a raw inbound row inserted the same way the NE Python does
//     (state=DELIVERED, incoming=1) is readable and mappable by the app.
//

import XCTest
import GRDB
import RNSAPI
@testable import ColumbaApp

final class MessageStoreTests: XCTestCase {
    private func temporaryDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-msgstore-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("lxmf-swift.db")
        // SQLite (GRDB) does not create parent directories; make the dir first.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - Schema freeze (the cross-process contract)

    func testMessageSchemaMatchesNEWriterContract() throws {
        let path = temporaryDatabaseURL().path
        _ = try MessageStore(path: path)
        let pool = try storePool(path: path)
        let columns = try schemaColumns(in: pool, "messages")
        // Exact column set the NE Python `INSERT OR REPLACE INTO messages (...)`
        // writes (rns_bridge.py). Order matters for the frozen contract; assert
        // the full set and the critical PK/FK/NOT-NULL-bearing columns.
        let expected: Set<String> = [
            "message_id", "conversation_hash", "destination_hash", "source_hash",
            "signature", "timestamp", "title", "content", "fields", "stamp",
            "state", "method", "delivery_attempts", "progress", "incoming",
            "rssi", "snr", "q", "ratchet_id", "packed_lxmf",
            "receiving_interface", "reply_to_id", "reactions_json",
            "created_at", "updated_at",
        ]
        XCTAssertEqual(Set(columns), expected,
                       "messages schema drifted from the NE writer contract")
        // message_id is the PK; conversation_hash is an FK to conversations.
        let pk = try primaryKeyColumns(in: pool, "messages")
        XCTAssertEqual(pk, ["message_id"], "messages PK changed")
        let fk = try foreignKeyTables(in: pool, "messages")
        XCTAssertEqual(fk, ["conversations"], "messages FK target changed")
    }

    func testConversationSchemaMatchesNEWriterContract() throws {
        let path = temporaryDatabaseURL().path
        _ = try MessageStore(path: path)
        let pool = try storePool(path: path)
        let columns = try schemaColumns(in: pool, "conversations")
        let expected: Set<String> = [
            "destination_hash", "display_name", "last_message_timestamp",
            "last_message_preview", "unread_count", "is_unread",
            "created_at", "updated_at", "is_favorite",
            "icon_name", "icon_fg_color", "icon_bg_color", "is_pinned",
        ]
        XCTAssertEqual(Set(columns), expected,
                       "conversations schema drifted from the NE writer contract")
        XCTAssertEqual(try primaryKeyColumns(in: pool, "conversations"), ["destination_hash"])
    }

    func testIndexesAreFrozen() throws {
        let path = temporaryDatabaseURL().path
        _ = try MessageStore(path: path)
        let pool = try storePool(path: path)
        let indexes = try indexNames(in: pool)
        let expected: Set<String> = [
            "idx_messages_conversation_timestamp", "idx_messages_state",
            "idx_messages_timestamp", "idx_conversations_last_timestamp",
            "idx_messages_reply_to",
        ]
        for name in expected {
            XCTAssertTrue(indexes.contains(name), "missing frozen index \(name)")
        }
    }

    // MARK: - State / method vocabulary round-trip

    func testStateVocabularyRoundTripsThroughMapper() {
        // Every semantic RNSAPI state maps to a byte and back without loss.
        for rns in [RNSAPI.LXMessageState.draft, .outbound, .sending, .sent, .delivered, .failed, .received] {
            let byte = MessageRepository.mapStateToGRDB(rns)
            let back = MessageRepository.mapState(byte)
            XCTAssertEqual(back, rns == .received ? .delivered : rns,
                           "state \(rns) round-trip: byte=\(byte) -> \(back)")
        }
    }

    func testMethodVocabularyRoundTripsThroughMapper() {
        for rns in [RNSAPI.LXDeliveryMethod.opportunistic, .direct, .propagated, .paper, .unknown] {
            let byte = MessageRepository.mapMethodToGRDB(rns)
            let back = MessageRepository.mapMethod(byte)
            XCTAssertEqual(back, rns, "method \(rns) round-trip: byte=\(byte) -> \(back)")
        }
    }

    func testStateBytesMatchFrozenLXMFSwiftValues() {
        // These are the bytes the NE Python writes; they must stay stable.
        XCTAssertEqual(GRDBState.generating.rawValue, 0x00)
        XCTAssertEqual(GRDBState.outbound.rawValue, 0x01)
        XCTAssertEqual(GRDBState.sending.rawValue, 0x02)
        XCTAssertEqual(GRDBState.sent.rawValue, 0x04)
        XCTAssertEqual(GRDBState.delivered.rawValue, 0x08)
        XCTAssertEqual(GRDBState.rejected.rawValue, 0xFD)
        XCTAssertEqual(GRDBState.cancelled.rawValue, 0xFE)
        XCTAssertEqual(GRDBState.failed.rawValue, 0xFF)
        XCTAssertEqual(GRDBDeliveryMethod.opportunistic.rawValue, 0x01)
        XCTAssertEqual(GRDBDeliveryMethod.direct.rawValue, 0x02)
        XCTAssertEqual(GRDBDeliveryMethod.propagated.rawValue, 0x03)
        XCTAssertEqual(GRDBDeliveryMethod.paper.rawValue, 0x05)
    }

    func testUnknownMethodPersistsAsSentinelZeroAndMapsBack() {
        XCTAssertEqual(MessageRepository.mapMethodToGRDB(.unknown), 0)
        XCTAssertEqual(MessageRepository.mapMethod(0), .unknown)
    }

    // MARK: - Store round-trip

    func testSaveAndReadMessageRowRoundTrips() async throws {
        let store = try MessageStore(path: temporaryDatabaseURL().path)
        let now = Date().timeIntervalSince1970
        let dest = Data(repeating: 0x0A, count: 16)
        let src = Data(repeating: 0x0B, count: 16)
        let msgId = Data(repeating: 0x0C, count: 32)
        let content = Data("hello from the app".utf8)

        let row = MessageRow(
            messageId: msgId,
            conversationHash: dest,
            destinationHash: dest,
            sourceHash: src,
            signature: Data(repeating: 0x11, count: 64),
            timestamp: now,
            title: Data(),
            content: content,
            fields: nil,
            stamp: nil,
            state: GRDBState.outbound.rawValue,
            method: GRDBDeliveryMethod.opportunistic.rawValue,
            deliveryAttempts: 0,
            progress: 0.0,
            incoming: false,
            rssi: nil, snr: nil, q: nil, ratchetId: nil,
            receivingInterface: "loopback",
            replyToId: nil, reactionsJson: nil,
            packedLxmf: Data(),
            createdAt: now, updatedAt: now
        )
        try await store.saveMessage(row)

        let readBack = try await store.getMessageRecord(id: msgId)
        XCTAssertNotNil(readBack)
        XCTAssertEqual(readBack?.messageId, msgId)
        XCTAssertEqual(readBack?.content, content)
        XCTAssertEqual(readBack?.incoming, false)
        XCTAssertEqual(readBack?.state, GRDBState.outbound.rawValue)
        XCTAssertEqual(readBack?.method, GRDBDeliveryMethod.opportunistic.rawValue)

        // Conversation upserted: outbound does NOT increment unread.
        let convo = try await store.getConversation(hash: dest)
        XCTAssertEqual(convo?.lastMessagePreview, "hello from the app")
        XCTAssertEqual(convo?.unreadCount, 0)
        XCTAssertEqual(convo?.isUnread, 0)
    }

    func testInboundRowIncrementsUnreadAndUsesSourceHashAsConversationKey() async throws {
        let store = try MessageStore(path: temporaryDatabaseURL().path)
        let now = Date().timeIntervalSince1970
        let dest = Data(repeating: 0x0A, count: 16)
        let src = Data(repeating: 0x0B, count: 16)
        let msgId = Data(repeating: 0x0D, count: 32)
        let row = MessageRow(
            messageId: msgId, conversationHash: src, destinationHash: dest, sourceHash: src,
            signature: Data(repeating: 0x22, count: 64), timestamp: now, title: Data(),
            content: Data("inbound msg".utf8), fields: nil, stamp: nil,
            state: GRDBState.delivered.rawValue, method: GRDBDeliveryMethod.opportunistic.rawValue,
            deliveryAttempts: 0, progress: 0.0, incoming: true,
            rssi: nil, snr: nil, q: nil, ratchetId: nil,
            receivingInterface: "auto", replyToId: nil, reactionsJson: nil,
            packedLxmf: Data(), createdAt: now, updatedAt: now
        )
        try await store.saveMessage(row)
        // Inbound conversation key is the SOURCE hash.
        let convo = try await store.getConversation(hash: src)
        XCTAssertEqual(convo?.unreadCount, 1)
        XCTAssertEqual(convo?.isUnread, 1)
        XCTAssertEqual(convo?.lastMessagePreview, "inbound msg")
    }

    // MARK: - Cross-process: app reads a row the NE Python would write

    func testAppReadsRawNEStyleInboundRow() async throws {
        // Simulate the NE Python's raw `INSERT OR REPLACE INTO messages` (state
        // = DELIVERED 0x08, incoming = 1, fields = NULL, packed_lxmf = the wire
        // bytes) by writing it through a plain GRDB pool, then read it back
        // through the app store and the field-map bridge. This proves the app can
        // consume NE-produced rows with no wire-library dependency in the store.
        let path = temporaryDatabaseURL().path
        let store = try MessageStore(path: path)
        // Let the store create the schema, then use a raw pool for the NE-style insert.
        let now = Date().timeIntervalSince1970
        let dest = Data(repeating: 0x0A, count: 16)
        let src = Data(repeating: 0x0B, count: 16)
        let msgId = Data(repeating: 0x0E, count: 32)
        let wire = Data((0..<200).map { UInt8($0) }) // stand-in for the signed wire bytes

        let pool = try DatabasePool(path: path)
        try await pool.write { db in
            // NE-style conversation upsert (raw SQL, mirroring rns_bridge.py):
            // omit is_pinned so the schema DEFAULT 0 applies; is_favorite is a
            // literal 0. The NE does both the conversation upsert and the message
            // insert in one connection, so the FK is satisfied by the time the
            // message row commits.
            let exists: Int? = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM conversations WHERE destination_hash = ?",
                arguments: [src]
            )
            if exists == nil {
                try db.execute(
                    sql: """
                        INSERT INTO conversations
                        (destination_hash, display_name, last_message_timestamp,
                         last_message_preview, unread_count, is_unread, is_favorite,
                         icon_name, icon_fg_color, icon_bg_color,
                         created_at, updated_at)
                        VALUES (?,?,?,?,?,?,0,NULL,NULL,NULL,?,?)
                        """,
                    arguments: [src, nil, now, "ne inbound", 1, 1, now, now]
                )
            }
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO messages
                    (message_id, conversation_hash, destination_hash, source_hash,
                     signature, timestamp, title, content, fields, stamp, state,
                     method, delivery_attempts, progress, incoming, rssi, snr, q,
                     ratchet_id, packed_lxmf, receiving_interface, reply_to_id,
                     reactions_json, created_at, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    msgId, src, dest, src,
                    Data(repeating: 0x33, count: 64), now, Data(), Data("ne inbound".utf8),
                    nil, nil, GRDBState.delivered.rawValue, GRDBDeliveryMethod.opportunistic.rawValue,
                    0, 0.0, 1, nil, nil, nil, nil, wire, "auto", nil, nil, now, now,
                ]
            )
        }
        // App reads it back.
        let row = try await store.getMessageRecord(id: msgId)
        XCTAssertNotNil(row, "app could not read the NE-style inbound row")
        XCTAssertEqual(row?.incoming, true)
        XCTAssertEqual(row?.state, GRDBState.delivered.rawValue)
        XCTAssertEqual(row?.packedLxmf, wire)
        // The field-map bridge: a non-field-map byte blob (stand-in wire) maps
        // through mapRecord without throwing (wire-with-fields would be unpacked
        // by the codec; a random blob falls through to the field-map passthrough).
        let record = MessageRepository.mapRecord(row!)
        XCTAssertEqual(record.direction, .inbound)
        XCTAssertEqual(record.state, RNSAPI.LXMessageState.delivered.rawValue)
        XCTAssertEqual(record.packedLxmf, wire)
    }

    // MARK: - makeRow preserves the RNSAPI field map in packed_lxmf

    func testMakeRowCarriesFieldMapInPackedLxmf() throws {
        var msg = RNSAPI.LXMessage(
            destinationHash: Data(repeating: 0x0A, count: 16),
            sourceIdentity: nil,
            content: Data("body".utf8),
            fields: [LxmfFields.FIELD_ICON_APPEARANCE: ["icon": "robot"]]
        )
        msg.sourceHash = Data(repeating: 0x0B, count: 16)
        msg.hash = Data(repeating: 0x0C, count: 32)
        msg.incoming = false
        let row = MessageRepository.makeRow(from: msg)
        // packed_lxmf is the MessagePack field map; the separate `fields` column is nil.
        XCTAssertFalse(row.packedLxmf.isEmpty)
        XCTAssertNil(row.fields)
        let recovered = LxmfFieldCodec.unpack(row.packedLxmf)
        XCTAssertNotNil(recovered, "field map must survive makeRow -> pack -> unpack")
        XCTAssertTrue(
            recovered?.keys.contains(LxmfFields.FIELD_ICON_APPEARANCE) == true,
            "the icon field key must be preserved in packed_lxmf"
        )
    }

    func testMakeRowExtractsReplyToFromAppData() throws {
        var msg = RNSAPI.LXMessage(
            destinationHash: Data(repeating: 0x0A, count: 16),
            sourceIdentity: nil,
            content: Data("reply".utf8),
            fields: [RNSAPI.LXMessage.FIELD_APP_DATA: ["reply_to": "abc123"]]
        )
        msg.sourceHash = Data(repeating: 0x0B, count: 16)
        msg.hash = Data(repeating: 0x0C, count: 32)
        msg.incoming = false
        let row = MessageRepository.makeRow(from: msg)
        XCTAssertEqual(row.replyToId, "abc123")
    }

    func testMakeRowUnknownMethodPersistsSentinelZero() throws {
        var msg = RNSAPI.LXMessage(
            destinationHash: Data(repeating: 0x0A, count: 16),
            sourceIdentity: nil,
            content: Data("x".utf8)
        )
        msg.sourceHash = Data(repeating: 0x0B, count: 16)
        msg.hash = Data(repeating: 0x0C, count: 32)
        msg.method = .unknown
        let row = MessageRepository.makeRow(from: msg)
        XCTAssertEqual(row.method, 0)
    }

    // MARK: - Load outbound IDs

    func testLoadPendingOutboundIdsReturnsOnlyMatchingStates() async throws {
        let store = try MessageStore(path: temporaryDatabaseURL().path)
        let now = Date().timeIntervalSince1970
        func make(id: UInt8, state: GRDBState, method: GRDBDeliveryMethod) -> MessageRow {
            MessageRow(
                messageId: Data(repeating: id, count: 32),
                conversationHash: Data(repeating: 0x0A, count: 16),
                destinationHash: Data(repeating: 0x0A, count: 16),
                sourceHash: Data(repeating: 0x0B, count: 16),
                signature: Data(repeating: 0x44, count: 64), timestamp: now, title: Data(),
                content: Data("c\(id)".utf8), fields: nil, stamp: nil,
                state: state.rawValue, method: method.rawValue,
                deliveryAttempts: 0, progress: 0.0, incoming: false,
                rssi: nil, snr: nil, q: nil, ratchetId: nil,
                receivingInterface: nil, replyToId: nil, reactionsJson: nil,
                packedLxmf: Data(), createdAt: now, updatedAt: now
            )
        }
        try await store.saveMessage(make(id: 0x01, state: .outbound, method: .opportunistic))
        try await store.saveMessage(make(id: 0x02, state: .sent, method: .opportunistic))
        try await store.saveMessage(make(id: 0x03, state: .sent, method: .propagated))
        try await store.saveMessage(make(id: 0x04, state: .failed, method: .opportunistic))

        let pending = try await store.loadPendingOutboundIds()
        // outbound (.outbound) + sent-small-packet (.sent & opportunistic/direct);
        // NOT .sent+propagated (terminal) and NOT .failed.
        let pendingSet = Set(pending)
        XCTAssertEqual(pendingSet,
                       [Data(repeating: 0x01, count: 32),
                        Data(repeating: 0x02, count: 32)])
        let failed = try await store.loadFailedOutboundIds()
        XCTAssertEqual(failed, [Data(repeating: 0x04, count: 32)])
    }
}

// MARK: - Schema introspection helpers (test-only)
//
// The store's `dbPool` is private and not reachable from a test extension, so
// these open their own pool on the same file the store already migrated. That is
// also closer to how the NE Python opens the file - an independent connection.

private func storePool(path: String) throws -> DatabasePool {
    var config = Configuration()
    config.readonly = true
    return try DatabasePool(path: path, configuration: config)
}

private func schemaColumns(in pool: DatabasePool, _ table: String) throws -> [String] {
    try pool.read { db in
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return rows.map { $0["name"] as String }
    }
}
private func primaryKeyColumns(in pool: DatabasePool, _ table: String) throws -> [String] {
    // `table` is one of this file's own literal schema names (never user input),
    // so interpolation is safe. Filtering/ordering happens in SQLite, which
    // avoids GRDB's `Row` pragma-value bridging (where `row["pk"] as? Int` does
    // not decode reliably).
    try pool.read { db in
        try String.fetchAll(
            db,
            sql: "SELECT name FROM pragma_table_info('\(table)') WHERE pk > 0 ORDER BY pk"
        )
    }
}
private func foreignKeyTables(in pool: DatabasePool, _ table: String) throws -> [String] {
    try pool.read { db in
        let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
        return rows.compactMap { $0["table"] as? String }
    }
}
private func indexNames(in pool: DatabasePool) throws -> [String] {
    try pool.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'")
        return rows.map { $0["name"] as String }
    }
}
