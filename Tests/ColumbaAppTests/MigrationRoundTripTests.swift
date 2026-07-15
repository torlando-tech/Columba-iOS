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
            packedLxmf: Data([0x04, 0x05]).base64EncodedString()
        )

        let interface = InterfaceExport(
            name: "TCP Hub",
            type: "tcp_client",
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

        // Message fields that drifted: String state/method + isIncoming direction.
        let incoming = try XCTUnwrap(restored.messages.first { $0.id == "0001" })
        XCTAssertTrue(incoming.isIncoming)
        XCTAssertEqual(incoming.state, "delivered")
        XCTAssertEqual(incoming.method, "direct")
        XCTAssertEqual(incoming.packedLxmf, Data([0x01, 0x02, 0x03]).base64EncodedString())

        let outgoing = try XCTUnwrap(restored.messages.first { $0.id == "0002" })
        XCTAssertFalse(outgoing.isIncoming)
        XCTAssertEqual(outgoing.state, "sent")
        XCTAssertEqual(outgoing.method, "propagated")

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

    /// A wrong password must fail the AES-GCM tag check rather than return garbage.
    func testWrongPasswordThrows() throws {
        let bundle = makeBundle()
        let json = try JSONEncoder().encode(bundle)
        let encrypted = try MigrationCrypto.encrypt(data: json, password: password)

        XCTAssertThrowsError(try MigrationCrypto.decrypt(data: encrypted, password: "wrong-password-9999")) { error in
            XCTAssertTrue(error is MigrationCryptoError, "expected a MigrationCryptoError, got \(error)")
        }
    }
}
#endif
