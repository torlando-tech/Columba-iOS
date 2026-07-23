//
//  MigrationRoundTripTests.swift
//  ColumbaAppTests
//
//  End-to-end round-trip coverage for the data-migration feature
//  (Settings → Data Migration). Exercises the real production path:
//  MigrationBundle Codable → MigrationCrypto AES-GCM/PBKDF2 →
//  MigrationImporter's decrypt+parse. Guards the .columba serialization
//  format — in particular the MessageExport/ConversationExport field
//  shapes that drifted against RNSAPI's domain types (MessageRecord.state /
//  .method became String; direction replaced `incoming`; the conversation
//  timestamp became a Date) and had never been compiled until the feature
//  was enabled via support/enable-migration.rb.
//

#if COLUMBA_MIGRATION_ENABLED
import XCTest
import RNSAPI
@testable import ColumbaApp

@available(macOS 14.0, iOS 17.0, *)
final class MigrationRoundTripTests: XCTestCase {

    private let password = "test-password-1234" // ≥ 8 chars, matches VM minimum

    /// Build a representative bundle touching every export type, with special
    /// attention to the fields that drifted (message state/method/isIncoming,
    /// conversation lastMessageTimestamp).
    private func makeBundle() -> MigrationBundle {
        let convTimestamp = Date(timeIntervalSince1970: 1_700_000_123)

        let identity = IdentityExport(
            identityHash: "aabbccdd",
            displayName: "Alice",
            destinationHash: "11223344",
            keyData: Data(repeating: 0x42, count: 64).base64EncodedString(),
            createdTimestamp: 1_699_000_000,
            lastUsedTimestamp: 1_700_000_000,
            isActive: true,
            iconName: "account",
            iconForegroundColor: "#FFFFFF",
            iconBackgroundColor: "#000000"
        )

        let conversation = ConversationExport(
            peerHash: "deadbeef",
            identityHash: "aabbccdd",
            peerName: "Bob",
            lastMessage: "hello",
            lastMessageTimestamp: convTimestamp.timeIntervalSince1970,
            unreadCount: 3,
            isFavorite: true,
            iconName: "robot",
            iconFgColor: "#111111",
            iconBgColor: "#222222"
        )

        let messageIn = MessageExport(
            id: "0001",
            conversationHash: "deadbeef",
            identityHash: "aabbccdd",
            timestamp: 1_700_000_100,
            isIncoming: true,
            state: "delivered",
            method: "direct",
            content: Data("hi there".utf8).base64EncodedString(),
            sourceHash: "cafebabe",
            packedLxmf: Data([0x01, 0x02, 0x03]).base64EncodedString()
        )
        let messageOut = MessageExport(
            id: "0002",
            conversationHash: "deadbeef",
            identityHash: "aabbccdd",
            timestamp: 1_700_000_200,
            isIncoming: false,
            state: "sent",
            method: "propagated",
            content: Data("reply".utf8).base64EncodedString(),
            sourceHash: "",
            packedLxmf: Data([0x04, 0x05]).base64EncodedString()
        )

        let interface = InterfaceExport(
            name: "TCP Hub",
            type: "tcp_client",
            mode: InterfaceMode.full.rawValue,
            enabled: true,
            configJson: "{\"host\":\"example\"}",
            displayOrder: 0
        )

        let settings = SettingsExport(preferences: [
            .string("displayName", "Alice"),
            .bool("notifications_enabled", true),
            .int("announce_interval_hours", 6),
            .double("syncIntervalSeconds", 43_200)
        ])

        return MigrationBundle(
            identities: [identity],
            conversations: [conversation],
            messages: [messageIn, messageOut],
            interfaces: [interface],
            settings: settings
        )
    }

    private func makeValidatedIdentityExport(
        identity: Identity = Identity(),
        identityHash: String? = nil,
        destinationHash: String? = nil,
        isActive: Bool = false
    ) throws -> IdentityExport {
        let canonicalDestination = Destination.hash(
            identity: identity,
            appName: "lxmf",
            aspects: ["delivery"]
        ).map { String(format: "%02x", $0) }.joined()
        return IdentityExport(
            identityHash: identityHash ?? identity.hexHash,
            displayName: "Validated Identity",
            destinationHash: destinationHash ?? canonicalDestination,
            keyData: try identity.exportPrivateKeys().base64EncodedString(),
            createdTimestamp: 1_699_000_000,
            lastUsedTimestamp: 1_700_000_000,
            isActive: isActive,
            iconName: nil,
            iconForegroundColor: nil,
            iconBackgroundColor: nil
        )
    }

    func testIdentityRestoreValidationBindsMetadataToPrivateKeys() throws {
        let export = try makeValidatedIdentityExport()
        let validated = try MigrationImporter.validateIdentityExports([export])
        XCTAssertEqual(validated.count, 1)
        XCTAssertEqual(validated[0].identityHash, export.identityHash.lowercased())
        XCTAssertEqual(validated[0].destinationHash, export.destinationHash.lowercased())
    }

    func testIdentityRestoreValidationRejectsIdentityHashMismatch() throws {
        let export = try makeValidatedIdentityExport(identityHash: "00")
        XCTAssertThrowsError(try MigrationImporter.validateIdentityExports([export])) { error in
            guard case MigrationIdentityValidationError.identityHashMismatch = error else {
                return XCTFail("Expected identityHashMismatch, got \(error)")
            }
        }
    }

    func testIdentityRestoreValidationRejectsDestinationHashMismatch() throws {
        let export = try makeValidatedIdentityExport(destinationHash: "00")
        XCTAssertThrowsError(try MigrationImporter.validateIdentityExports([export])) { error in
            guard case MigrationIdentityValidationError.destinationHashMismatch = error else {
                return XCTFail("Expected destinationHashMismatch, got \(error)")
            }
        }
    }

    func testIdentityRestoreValidationRejectsDuplicateHashes() throws {
        let export = try makeValidatedIdentityExport()
        XCTAssertThrowsError(try MigrationImporter.validateIdentityExports([export, export])) { error in
            guard case MigrationIdentityValidationError.duplicateIdentity = error else {
                return XCTFail("Expected duplicateIdentity, got \(error)")
            }
        }
    }

    func testIdentityRestoreValidationRejectsDuplicateClaimWithDifferentKeys() throws {
        let first = try makeValidatedIdentityExport()
        let second = try makeValidatedIdentityExport(identityHash: first.identityHash)
        XCTAssertThrowsError(try MigrationImporter.validateIdentityExports([first, second]))
    }

    func testImportedIdentityMetadataPersistsAcrossManagerInstances() async throws {
        let hash = "test-restore-\(UUID().uuidString.lowercased())"
        let local = LocalIdentity(
            identityHash: hash,
            displayName: "Restore Persistence Test",
            destinationHash: "destination-\(hash)",
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: Date().timeIntervalSince1970,
            isActive: false
        )
        let manager = IdentityManager()
        try await manager.importIdentityRecord(local)

        let reloaded = IdentityManager()
        let persisted = await reloaded.getAllIdentities()
        XCTAssertTrue(persisted.contains(where: { $0.identityHash == hash }))

        try await manager.deleteIdentity(hash)
    }

    func testRestorePrefersBackupActiveIdentityAndFallsBackToFirst() throws {
        let first = try makeValidatedIdentityExport()
        let active = try makeValidatedIdentityExport(isActive: true)
        let validated = try MigrationImporter.validateIdentityExports([first, active])
        XCTAssertEqual(
            MigrationImporter.preferredIdentityHash(from: validated),
            validated[1].identityHash
        )
        XCTAssertEqual(
            MigrationImporter.preferredIdentityHash(from: [validated[0]]),
            validated[0].identityHash
        )
        XCTAssertNil(MigrationImporter.preferredIdentityHash(from: []))
    }

    func testHistoryOwnerValidationRejectsMissingOrForeignIdentity() {
        XCTAssertThrowsError(try MigrationImporter.validateRecordOwnerHashes(
            ["aabbccdd"],
            canonicalIdentityHashes: []
        )) { error in
            guard case MigrationIdentityValidationError.unknownIdentityOwner = error else {
                return XCTFail("Expected unknownIdentityOwner, got \(error)")
            }
        }
        XCTAssertThrowsError(try MigrationImporter.validateRecordOwnerHashes(
            ["aabbccdd"],
            canonicalIdentityHashes: ["11223344"]
        ))
    }

    func testHistoryOwnerValidationRejectsUppercaseReference() {
        XCTAssertThrowsError(try MigrationImporter.validateRecordOwnerHashes(
            ["AABBCCDD"],
            canonicalIdentityHashes: ["aabbccdd"]
        )) { error in
            guard case MigrationIdentityValidationError.nonCanonicalIdentityOwner = error else {
                return XCTFail("Expected nonCanonicalIdentityOwner, got \(error)")
            }
        }
    }

    func testHistoryOwnerValidationAcceptsCanonicalBackupIdentity() throws {
        try MigrationImporter.validateRecordOwnerHashes(
            ["aabbccdd", "aabbccdd"],
            canonicalIdentityHashes: ["aabbccdd"]
        )
    }

    func testInterfaceModeValidationDefaultsOnlyMissingLegacyMode() throws {
        XCTAssertEqual(try MigrationImporter.validatedInterfaceMode(nil), .full)
        XCTAssertEqual(
            try MigrationImporter.validatedInterfaceMode(InterfaceMode.gateway.rawValue),
            .gateway
        )
        XCTAssertThrowsError(try MigrationImporter.validatedInterfaceMode("future-unsupported-mode")) { error in
            guard case MigrationInterfaceValidationError.unsupportedMode = error else {
                return XCTFail("Expected unsupportedMode, got \(error)")
            }
        }
    }

    /// Encode → encrypt → decrypt → decode must preserve every field, with
    /// exact attention to the drifted message/conversation fields.
    func testEncryptedBundleRoundTrip() throws {
        let bundle = makeBundle()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(bundle)

        let encrypted = try MigrationCrypto.encrypt(data: json, password: password)
        XCTAssertTrue(MigrationCrypto.isEncrypted(encrypted), "encrypted blob must carry the .columba header")
        XCTAssertNotEqual(encrypted, json, "ciphertext must differ from plaintext")

        let decrypted = try MigrationCrypto.decrypt(data: encrypted, password: password)
        let restored = try JSONDecoder().decode(MigrationBundle.self, from: decrypted)

        XCTAssertEqual(restored.version, MigrationBundle.currentVersion)
        XCTAssertEqual(restored.platform, "iOS")
        XCTAssertEqual(restored.identities.count, 1)
        XCTAssertEqual(restored.conversations.count, 1)
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertEqual(restored.interfaces.count, 1)
        XCTAssertEqual(restored.interfaces.first?.mode, InterfaceMode.full.rawValue)

        // Identity survives with key material intact.
        let id = try XCTUnwrap(restored.identities.first)
        XCTAssertEqual(id.displayName, "Alice")
        XCTAssertEqual(id.keyData, Data(repeating: 0x42, count: 64).base64EncodedString())
        XCTAssertTrue(id.isActive)

        // Conversation timestamp (was a Date at the source) survives as epoch seconds.
        let conv = try XCTUnwrap(restored.conversations.first)
        XCTAssertEqual(conv.lastMessageTimestamp, 1_700_000_123, accuracy: 0.5)
        XCTAssertTrue(conv.isFavorite)
        XCTAssertEqual(conv.unreadCount, 3)

        // Message fields that drifted: String state/method + isIncoming direction,
        // plus the message body content (must survive — see the persistence test).
        let incoming = try XCTUnwrap(restored.messages.first { $0.id == "0001" })
        XCTAssertTrue(incoming.isIncoming)
        XCTAssertEqual(incoming.state, "delivered")
        XCTAssertEqual(incoming.method, "direct")
        XCTAssertEqual(Data(base64Encoded: incoming.content), Data("hi there".utf8))
        XCTAssertEqual(incoming.sourceHash, "cafebabe")
        XCTAssertEqual(incoming.packedLxmf, Data([0x01, 0x02, 0x03]).base64EncodedString())

        let outgoing = try XCTUnwrap(restored.messages.first { $0.id == "0002" })
        XCTAssertFalse(outgoing.isIncoming)
        XCTAssertEqual(outgoing.state, "sent")
        XCTAssertEqual(outgoing.method, "propagated")
        XCTAssertEqual(Data(base64Encoded: outgoing.content), Data("reply".utf8))

        // Settings preferences survive.
        XCTAssertEqual(restored.settings.preferences.count, 4)
    }

    /// The real importer's decrypt+parse path (previewMigration → decryptAndParse)
    /// must read an encrypted bundle and report accurate counts.
    func testPreviewMigrationReadsEncryptedBundle() async throws {
        let bundle = makeBundle()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encrypted = try MigrationCrypto.encrypt(data: encoder.encode(bundle), password: password)

        let importer = MigrationImporter(
            identityManager: IdentityManager(),
            settingsRepository: SettingsRepository()
        )

        let preview = try await importer.previewMigration(data: encrypted, password: password)
        XCTAssertEqual(preview.version, MigrationBundle.currentVersion)
        XCTAssertEqual(preview.platform, "iOS")
        XCTAssertEqual(preview.identityNames, ["Alice"])
        XCTAssertEqual(preview.identityCount, 1)
        XCTAssertEqual(preview.conversationCount, 1)
        XCTAssertEqual(preview.messageCount, 2)
        XCTAssertEqual(preview.interfaceCount, 1)
        XCTAssertEqual(preview.settingsCount, 4)
    }

    /// The message persistence path (the fix): a restored MessageRecord must
    /// keep its real content and field map through a genuine SQLite write+read.
    /// Guards against the earlier bug where import round-tripped through the
    /// `LXMessage.unpackFromBytes`/`pack()` Compat stubs and persisted an empty
    /// placeholder (blank content, zeroed hash), silently corrupting history.
    func testImportedMessageRecordPersistsRealContent() throws {
        let dbPath = NSTemporaryDirectory() + "migration-persist-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try LXMFDatabase(path: dbPath)

        let convHash = Data([0xde, 0xad, 0xbe, 0xef])
        let msgId = Data([0x00, 0x01])
        let body = Data("the real message body".utf8)
        let fieldMap = Data([0x81, 0x06, 0xc0]) // stand-in MessagePack field map

        let record = MessageRecord(
            id: msgId,
            conversationHash: convHash,
            content: body,
            timestamp: 1_700_000_500,
            direction: .inbound,
            state: "delivered",
            messageId: msgId,
            method: "direct",
            packedLxmf: fieldMap
        )
        db.saveMessageRecord(record)

        // Re-open from disk to prove it was actually persisted, not just cached.
        let reopened = try LXMFDatabase(path: dbPath)
        let rows = try reopened.getMessageRecords(forConversation: convHash, limit: 10, offset: 0)
        let restored = try XCTUnwrap(rows.first { $0.id == msgId },
                                     "message must be persisted and readable")
        XCTAssertEqual(restored.content, body, "content must survive — not a blank placeholder")
        XCTAssertFalse(restored.content.isEmpty, "content must not be empty")
        XCTAssertEqual(restored.direction, .inbound)
        XCTAssertEqual(restored.packedLxmf, fieldMap, "field map (attachments/icon) must survive")
    }

    /// Restored conversations must reconcile their list-preview metadata
    /// (preview text, last-message timestamp for ordering, unread badge) — not
    /// stay at the blank `ensureConversation` defaults.
    func testConversationMetadataReconciledOnImport() throws {
        let dbPath = NSTemporaryDirectory() + "migration-conv-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try LXMFDatabase(path: dbPath)

        let convHash = Data([0xde, 0xad, 0xbe, 0xef])
        try db.ensureConversation(hash: convHash, displayName: "Bob")
        // Mirror the importer: apply the backup's preview/timestamp/unread.
        try db.setConversationMetadata(
            hash: convHash,
            lastMessage: "see you then",
            lastMessageAt: Date(timeIntervalSince1970: 1_700_000_900),
            unreadCount: 5
        )

        let reopened = try LXMFDatabase(path: dbPath)
        let convs = try reopened.getConversations(limit: 10, offset: 0)
        let restored = try XCTUnwrap(convs.first { $0.hash == convHash })
        XCTAssertEqual(restored.lastMessage, "see you then", "preview must be restored")
        XCTAssertEqual(restored.lastMessageAt, Date(timeIntervalSince1970: 1_700_000_900),
                       "last-message timestamp must be restored for correct ordering")
        XCTAssertEqual(restored.unreadCount, 5, "unread badge must be restored")
    }

    /// A wrong password must fail the AES-GCM tag check rather than return garbage.
    func testWrongPasswordThrows() throws {
        let bundle = makeBundle()
        let json = try JSONEncoder().encode(bundle)
        let encrypted = try MigrationCrypto.encrypt(data: json, password: password)

        XCTAssertThrowsError(try MigrationCrypto.decrypt(data: encrypted, password: "wrong-password-9999")) { error in
            XCTAssertTrue(error is MigrationCryptoError, "expected a MigrationCryptoError, got \(error)")
        }
    }

    @MainActor
    func testExportPickerCancellationReturnsToRetryableIdleState() {
        let viewModel = MigrationViewModel(
            identityManager: IdentityManager(),
            settingsRepository: SettingsRepository()
        )

        viewModel.handleExportSaveResult(.failure(CocoaError(.userCancelled)))
        viewModel.exportPassword = password
        viewModel.exportPasswordConfirm = password

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(viewModel.canStartExport)
    }

    @MainActor
    func testExportPickerFailureRemainsVisibleAndRetryable() {
        let viewModel = MigrationViewModel(
            identityManager: IdentityManager(),
            settingsRepository: SettingsRepository()
        )
        let saveError = NSError(
            domain: "MigrationExportFlowTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "write denied"]
        )

        viewModel.handleExportSaveResult(.failure(saveError))
        viewModel.exportPassword = password
        viewModel.exportPasswordConfirm = password

        XCTAssertEqual(viewModel.state, .error(message: "Save failed: write denied"))
        XCTAssertTrue(viewModel.canStartExport)
    }
}
#endif
