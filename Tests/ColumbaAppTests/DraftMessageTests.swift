import XCTest
import GRDB
@testable import ColumbaApp

final class DraftMessageTests: XCTestCase {
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-drafts-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
    }

    func testDraftRoundTripsWithoutChangingWhitespace() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0x11, count: 16)
        let content = "  keep this draft exactly  \n"

        try await repository.ensureConversation(conversationHash, displayName: nil)
        let beforeSave = Date()
        try await repository.saveDraft(content, for: conversationHash)
        let storedDraft = try await repository.fetchDraft(for: conversationHash)
        let draft = try XCTUnwrap(storedDraft)

        XCTAssertEqual(draft.conversationHash, conversationHash)
        XCTAssertEqual(draft.content, content)
        XCTAssertGreaterThanOrEqual(draft.updatedAt, beforeSave)
        XCTAssertLessThanOrEqual(draft.updatedAt, Date())
    }

    func testWhitespaceOnlyDraftDeletesExistingDraft() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0x22, count: 16)

        try await repository.ensureConversation(conversationHash, displayName: nil)
        try await repository.saveDraft("keep me", for: conversationHash)
        try await repository.saveDraft(" \t\n ", for: conversationHash)

        let storedDraft = try await repository.fetchDraft(for: conversationHash)
        let drafts = try await repository.fetchDrafts()
        XCTAssertNil(storedDraft)
        XCTAssertTrue(drafts.isEmpty)
    }

    func testSavingAgainReplacesDraftForConversation() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0x33, count: 16)

        try await repository.ensureConversation(conversationHash, displayName: nil)
        try await repository.saveDraft("first", for: conversationHash)
        let storedFirst = try await repository.fetchDraft(for: conversationHash)
        let first = try XCTUnwrap(storedFirst)
        try await Task.sleep(nanoseconds: 1_000_000)
        try await repository.saveDraft("second", for: conversationHash)
        let storedReplacement = try await repository.fetchDraft(for: conversationHash)
        let replacement = try XCTUnwrap(storedReplacement)
        let drafts = try await repository.fetchDrafts()

        XCTAssertEqual(replacement.content, "second")
        XCTAssertGreaterThan(replacement.updatedAt, first.updatedAt)
        XCTAssertEqual(drafts[conversationHash], replacement)
        XCTAssertEqual(Set(drafts.keys), Set([conversationHash]))
    }

    func testDraftsAreIsolatedByConversation() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let firstHash = Data(repeating: 0x44, count: 16)
        let secondHash = Data(repeating: 0x55, count: 16)

        try await repository.ensureConversation(firstHash, displayName: nil)
        try await repository.ensureConversation(secondHash, displayName: nil)
        try await repository.saveDraft("first conversation", for: firstHash)
        try await repository.saveDraft("second conversation", for: secondHash)

        let firstDraft = try await repository.fetchDraft(for: firstHash)
        let secondDraft = try await repository.fetchDraft(for: secondHash)
        let drafts = try await repository.fetchDrafts()
        XCTAssertEqual(firstDraft?.content, "first conversation")
        XCTAssertEqual(secondDraft?.content, "second conversation")
        XCTAssertEqual(drafts[firstHash]?.content, "first conversation")
        XCTAssertEqual(drafts[secondHash]?.content, "second conversation")
        XCTAssertEqual(Set(drafts.keys), Set([firstHash, secondHash]))
    }

    func testDraftConversationHashRejectsNull() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        _ = try MessageRepository(grdbPath: databaseURL.path)
        let database = try DatabaseQueue(path: databaseURL.path)

        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO columba_drafts (conversation_hash, content, updated_at)
                        VALUES (NULL, 'invalid', 0)
                        """
                )
            }
        )
    }

    func testDraftsAreIsolatedByDatabasePath() async throws {
        let firstURL = temporaryDatabaseURL()
        let secondURL = temporaryDatabaseURL()
        defer {
            removeDatabase(at: firstURL)
            removeDatabase(at: secondURL)
        }
        let firstRepository = try MessageRepository(grdbPath: firstURL.path)
        let secondRepository = try MessageRepository(grdbPath: secondURL.path)
        let conversationHash = Data(repeating: 0x66, count: 16)

        try await firstRepository.ensureConversation(conversationHash, displayName: nil)
        try await secondRepository.ensureConversation(conversationHash, displayName: nil)
        try await firstRepository.saveDraft("identity one", for: conversationHash)

        let firstDraft = try await firstRepository.fetchDraft(for: conversationHash)
        let secondDraft = try await secondRepository.fetchDraft(for: conversationHash)
        XCTAssertEqual(firstDraft?.content, "identity one")
        XCTAssertNil(secondDraft)
    }

    func testDeletingConversationCascadesToDraft() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0x77, count: 16)

        try await repository.ensureConversation(conversationHash, displayName: nil)
        try await repository.saveDraft("temporary", for: conversationHash)
        try await repository.deleteConversation(conversationHash)

        let storedDraft = try await repository.fetchDraft(for: conversationHash)
        XCTAssertNil(storedDraft)
    }

    func testNotificationIsPostedAfterCommittedDraftIsReadable() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let writer = try MessageRepository(grdbPath: databaseURL.path)
        let reader = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0x88, count: 16)
        let readable = expectation(description: "Draft is readable when notification arrives")

        try await writer.ensureConversation(conversationHash, displayName: nil)
        let observer = NotificationCenter.default.addObserver(
            forName: MessageRepository.draftChangedNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let notifiedHash = notification.userInfo?[MessageRepository.conversationHashUserInfoKey] as? Data,
                  notifiedHash == conversationHash,
                  notification.userInfo?.count == 1 else { return }
            Task {
                if try await reader.fetchDraft(for: conversationHash)?.content == "committed" {
                    readable.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await writer.saveDraft("committed", for: conversationHash)

        await fulfillment(of: [readable], timeout: 1.0)
    }
}
