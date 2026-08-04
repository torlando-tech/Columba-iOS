import XCTest
import GRDB
@testable import ColumbaApp

final class DraftMessageTests: XCTestCase {
    private enum DraftSnapshot: Equatable {
        case missing
        case present(String)
        case readFailed
    }

    private final class NotificationReads: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []
        private var snapshots: [Data: [DraftSnapshot]] = [:]

        func track(_ task: Task<Void, Never>) {
            lock.lock()
            tasks.append(task)
            lock.unlock()
        }

        func append(_ snapshot: DraftSnapshot, for conversationHash: Data) {
            lock.lock()
            snapshots[conversationHash, default: []].append(snapshot)
            lock.unlock()
        }

        func snapshots(for conversationHash: Data) -> [DraftSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots[conversationHash, default: []]
        }

        private func trackedTasks() -> [Task<Void, Never>] {
            lock.lock()
            defer { lock.unlock() }
            return tasks
        }

        func cancelAndWaitForTasks() async {
            let trackedTasks = trackedTasks()
            trackedTasks.forEach { $0.cancel() }
            for task in trackedTasks {
                await task.value
            }
        }
    }

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
        try await repository.saveDraft("second", for: conversationHash)
        let storedReplacement = try await repository.fetchDraft(for: conversationHash)
        let replacement = try XCTUnwrap(storedReplacement)
        let drafts = try await repository.fetchDrafts()

        XCTAssertEqual(replacement.content, "second")
        XCTAssertTrue(replacement.updatedAt.timeIntervalSince1970.isFinite)
        XCTAssertGreaterThan(replacement.updatedAt.timeIntervalSince1970, 0)
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
        let reads = NotificationReads()

        try await writer.ensureConversation(conversationHash, displayName: nil)
        let observer = NotificationCenter.default.addObserver(
            forName: MessageRepository.draftChangedNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let notifiedHash = notification.userInfo?[MessageRepository.conversationHashUserInfoKey] as? Data,
                  notifiedHash == conversationHash,
                  notification.userInfo?.count == 1 else { return }
            let task = Task {
                if try await reader.fetchDraft(for: conversationHash)?.content == "committed" {
                    readable.fulfill()
                }
            }
            reads.track(task)
        }

        do {
            try await writer.saveDraft("committed", for: conversationHash)
            await fulfillment(of: [readable], timeout: 1.0)
        } catch {
            NotificationCenter.default.removeObserver(observer)
            await reads.cancelAndWaitForTasks()
            throw error
        }
        NotificationCenter.default.removeObserver(observer)
        await reads.cancelAndWaitForTasks()
    }

    func testOverlappingSaveAndClearNotifyCommittedStateInMutationOrder() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let writer = try MessageRepository(grdbPath: databaseURL.path)
        let reader = try MessageRepository(grdbPath: databaseURL.path)
        let reads = NotificationReads()
        let hashes = (0..<12).map { Data(repeating: UInt8(0x90 + $0), count: 16) }

        for conversationHash in hashes {
            try await writer.ensureConversation(conversationHash, displayName: nil)
            try await writer.saveDraft("baseline", for: conversationHash)
        }

        let observer = NotificationCenter.default.addObserver(
            forName: MessageRepository.draftChangedNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let conversationHash = notification.userInfo?[MessageRepository.conversationHashUserInfoKey] as? Data,
                  hashes.contains(conversationHash) else { return }

            // NotificationCenter invokes this observer synchronously. Waiting on
            // a distinct repository captures the durable state at notification
            // time before the writer can begin its next actor-isolated mutation.
            let finished = DispatchSemaphore(value: 0)
            let task = Task {
                do {
                    let draft = try await reader.fetchDraft(for: conversationHash)
                    reads.append(draft.map { .present($0.content) } ?? .missing, for: conversationHash)
                } catch {
                    reads.append(.readFailed, for: conversationHash)
                }
                finished.signal()
            }
            reads.track(task)
            _ = finished.wait(timeout: .now() + 2)
        }

        do {
            for (index, conversationHash) in hashes.enumerated() {
                let replacement = "replacement-\(index)"
                async let save: Void = writer.saveDraft(replacement, for: conversationHash)
                async let clear: Void = writer.clearDraft(for: conversationHash)
                _ = try await (save, clear)

                let snapshots = reads.snapshots(for: conversationHash)
                let finalDraft = try await writer.fetchDraft(for: conversationHash)
                let saveThenClear: [DraftSnapshot] = [.present(replacement), .missing]
                let clearThenSave: [DraftSnapshot] = [.missing, .present(replacement)]

                XCTAssertTrue(
                    snapshots == saveThenClear || snapshots == clearThenSave,
                    "Each notification must expose its own committed mutation; got \(snapshots)"
                )
                XCTAssertEqual(
                    snapshots.last,
                    finalDraft.map { .present($0.content) } ?? .missing
                )
            }
        } catch {
            NotificationCenter.default.removeObserver(observer)
            await reads.cancelAndWaitForTasks()
            throw error
        }

        NotificationCenter.default.removeObserver(observer)
        await reads.cancelAndWaitForTasks()
    }
}
