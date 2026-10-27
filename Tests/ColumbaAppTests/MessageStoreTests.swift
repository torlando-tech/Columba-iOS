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
#if os(iOS)
import UIKit
#endif
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
            // App-owned extension: the send-time outgoing-interface snapshot.
            // The NE writer never touches it (inbound rows keep it NULL), so
            // it is absent from the NE INSERT column list by design.
            "sent_interface",
        ]
        XCTAssertEqual(Set(columns), expected,
                       "messages schema drifted from the NE writer contract")
        // message_id is the PK; conversation_hash is an FK to conversations.
        let pk = try primaryKeyColumns(in: pool, "messages")
        XCTAssertEqual(pk, ["message_id"], "messages PK changed")
        let fk = try foreignKeyTables(in: pool, "messages")
        XCTAssertEqual(fk, ["conversations"], "messages FK target changed")

        // Column types are part of the frozen contract too: a .blob <-> .text
        // drift would silently corrupt cross-process data the NE writes.
        let types = try columnTypes(in: pool, "messages")
        let expectedTypes: [String: String] = [
            "message_id": "BLOB", "conversation_hash": "BLOB", "destination_hash": "BLOB",
            "source_hash": "BLOB", "signature": "BLOB", "timestamp": "DOUBLE", "title": "BLOB",
            "content": "BLOB", "fields": "BLOB", "stamp": "BLOB", "state": "INTEGER",
            "method": "INTEGER", "delivery_attempts": "INTEGER", "progress": "DOUBLE",
            "incoming": "INTEGER", "rssi": "DOUBLE", "snr": "DOUBLE", "q": "DOUBLE",
            "ratchet_id": "BLOB", "packed_lxmf": "BLOB", "created_at": "DOUBLE",
            "updated_at": "DOUBLE", "receiving_interface": "TEXT", "reply_to_id": "TEXT",
            "reactions_json": "TEXT", "sent_interface": "TEXT",
        ]
        XCTAssertEqual(types, expectedTypes, "messages column types drifted")

        // Required (NOT NULL) columns: the NE writer must satisfy these on every
        // INSERT, so a drift here breaks inbound delivery.
        let notNull = try notNullColumns(in: pool, "messages")
        let expectedNotNull: Set<String> = [
            "message_id", "conversation_hash", "destination_hash", "source_hash",
            "signature", "timestamp", "content", "state", "method", "incoming",
            "packed_lxmf", "created_at", "updated_at",
        ]
        XCTAssertEqual(Set(notNull), expectedNotNull, "messages NOT NULL set drifted")

        // FK columns + delete behavior: deleting a conversation must cascade to
        // its messages. A name-only check (above) would still pass if .cascade
        // were dropped, while breaking conversation deletion.
        let fkDetails = try foreignKeyDetails(in: pool, "messages")
        XCTAssertEqual(fkDetails.count, 1, "messages FK count changed")
        if let fk = fkDetails.first {
            XCTAssertEqual(fk.0, "conversations", "messages FK target table drifted")
            XCTAssertEqual(fk.1, "conversation_hash", "messages FK from-column drifted")
            XCTAssertEqual(fk.2, "destination_hash", "messages FK to-column drifted")
            XCTAssertEqual(fk.3, "CASCADE", "messages FK on_delete drifted (cascade lost)")
        }
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

        // Column types + NOT NULL: same cross-process contract as messages.
        let types = try columnTypes(in: pool, "conversations")
        let expectedTypes: [String: String] = [
            "destination_hash": "BLOB", "display_name": "TEXT", "last_message_timestamp": "DOUBLE",
            "last_message_preview": "TEXT", "unread_count": "INTEGER", "is_unread": "INTEGER",
            "created_at": "DOUBLE", "updated_at": "DOUBLE", "is_favorite": "INTEGER",
            "icon_name": "TEXT", "icon_fg_color": "TEXT", "icon_bg_color": "TEXT",
            "is_pinned": "INTEGER",
        ]
        XCTAssertEqual(types, expectedTypes, "conversations column types drifted")
        let notNull = try notNullColumns(in: pool, "conversations")
        XCTAssertEqual(Set(notNull), ["destination_hash", "created_at", "updated_at"],
                       "conversations NOT NULL set drifted")
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

// GRDB 6.29 observes suspension only on NotificationCenter.default, with no
// pool-specific object filtering. Keep these process-wide transitions on the
// main actor and always restore resumed access, even when an assertion fails.
@MainActor
final class MessageRepositorySuspensionTests: XCTestCase {
    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-repository-suspension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("lxmf-swift.db")
    }

    private func assertAnnouncedNameWriteIsSuspended(
        _ repository: MessageRepository,
        destination: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await repository.applyAnnouncedDisplayName(
                destination,
                displayName: "Announced Peer"
            )
            XCTFail("A suspended repository must reject its announced-name write", file: file, line: line)
        } catch let error as DatabaseError {
            XCTAssertTrue(
                error.resultCode == .SQLITE_ABORT || error.resultCode == .SQLITE_INTERRUPT,
                "Expected a suspension error, received \(error)",
                file: file,
                line: line
            )
        }
    }

    func testAnnouncedNameWriteAbortsWhileSuspendedAndResumesWithoutOverwritingNickname() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let center = NotificationCenter.default
        defer { center.post(name: Database.resumeNotification, object: nil) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data([0x05, 0xc5, 0x7e, 0x42] + Array(repeating: 0xaa, count: 12))
        let customDestination = Data(repeating: 0xbb, count: 16)
        let fallbackName = "Peer 05c57e42"
        try await repository.ensureConversation(destination, displayName: fallbackName)
        try await repository.ensureConversation(customDestination, displayName: nil)
        try await repository.updateDisplayName(customDestination, displayName: "My Server")

        center.post(name: Database.suspendNotification, object: nil)
        try await assertAnnouncedNameWriteIsSuspended(repository, destination: destination)
        center.post(name: Database.resumeNotification, object: nil)

        let afterAbort = try await repository.fetchConversation(destination)
        XCTAssertEqual(try XCTUnwrap(afterAbort).displayName, fallbackName,
                       "The rejected write must not have committed")
        let applied = try await repository.applyAnnouncedDisplayName(destination, displayName: "Announced Peer")
        XCTAssertTrue(applied)
        let afterResume = try await repository.fetchConversation(destination)
        XCTAssertEqual(try XCTUnwrap(afterResume).displayName, "Announced Peer")

        let customApplied = try await repository.applyAnnouncedDisplayName(
            customDestination,
            displayName: "Announced Replacement"
        )
        XCTAssertFalse(customApplied)
        let customConversation = try await repository.fetchConversation(customDestination)
        XCTAssertEqual(try XCTUnwrap(customConversation).displayName, "My Server")
    }

    #if os(iOS)
    func testApplicationBackgroundNotificationSuspendsRealRepositoryUntilForeground() async throws {
        let databaseURL = try temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let center = NotificationCenter.default
        defer {
            center.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
            center.post(name: Database.resumeNotification, object: nil)
        }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data([0x05, 0xc5, 0x7e, 0x42] + Array(repeating: 0xcc, count: 12))
        let fallbackName = "Peer 05c57e42"
        try await repository.ensureConversation(destination, displayName: fallbackName)

        // The hosted app installs the real process lifecycle observers at init.
        // Do not issue a GRDB suspension directly: missing UIKit-to-GRDB wiring
        // must fail this regression even if the pools already opt into GRDB.
        center.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        try await assertAnnouncedNameWriteIsSuspended(repository, destination: destination)
        center.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)

        let afterAbort = try await repository.fetchConversation(destination)
        XCTAssertEqual(try XCTUnwrap(afterAbort).displayName, fallbackName,
                       "The backgrounded write must not have committed")
        let applied = try await repository.applyAnnouncedDisplayName(destination, displayName: "Announced Peer")
        XCTAssertTrue(applied)
        let afterForeground = try await repository.fetchConversation(destination)
        XCTAssertEqual(try XCTUnwrap(afterForeground).displayName, "Announced Peer")
    }
    #endif
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
private func columnTypes(in pool: DatabasePool, _ table: String) throws -> [String: String] {
    // `PRAGMA table_info` `type` is the declared column type (BLOB/TEXT/INTEGER/
    // REAL, uppercase). The frozen contract pins it per-column.
    try pool.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT name, type FROM pragma_table_info('\(table)')")
        var result: [String: String] = [:]
        for row in rows { result[row["name"] as String] = row["type"] as? String }
        return result
    }
}
private func notNullColumns(in pool: DatabasePool, _ table: String) throws -> [String] {
    // Filtering happens in SQLite (`WHERE notnull = 1`), avoiding GRDB's
    // `Row` pragma-value bridging for the 0/1 `notnull` flag.
    try pool.read { db in
        try String.fetchAll(
            db,
            sql: "SELECT name FROM pragma_table_info('\(table)') WHERE \"notnull\" = 1"
        )
    }
}
private func foreignKeyDetails(
    in pool: DatabasePool, _ table: String
) throws -> [(String, String, String, String)] {
    // Full FK contract: referenced table, from-column, to-column, and on_delete
    // behavior (CASCADE/NO ACTION/... uppercase). A name-only check would miss a
    // dropped `.cascade` that breaks conversation deletion.
    try pool.read { db in
        let rows = try Row.fetchAll(
            db, sql: "SELECT \"table\", \"from\", \"to\", \"on_delete\" FROM pragma_foreign_key_list('\(table)')"
        )
        return rows.compactMap { row in
            guard let t = row["table"] as? String,
                  let from = row["from"] as? String,
                  let to = row["to"] as? String,
                  let onDelete = row["on_delete"] as? String else { return nil }
            return (t, from, to, onDelete)
        }
    }
}
private func indexNames(in pool: DatabasePool) throws -> [String] {
    try pool.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'")
        return rows.map { $0["name"] as String }
    }
}
