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
            let task = Task<Void, Never> {
                do {
                    if try await reader.fetchDraft(for: conversationHash)?.content == "committed" {
                        readable.fulfill()
                    }
                } catch {
                    XCTFail("Draft read after notification failed: \(error)")
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

private final class ControlledDraftSleeper: @unchecked Sendable {
    private enum Registration {
        case cancelledBeforeRegistration
        case waiting(CheckedContinuation<Void, Error>)
        case completed
    }

    private let lock = NSLock()
    private var registrations: [UUID: Registration] = [:]
    private var invocationCountStorage = 0
    var onSleep: (() -> Void)?
    var onBeforeRegistrationLock: (() -> Void)?

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCountStorage
    }

    var pendingRegistrationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.count
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        defer { finish(id: id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation, id: id)
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    func resumeAll() {
        let pending: [CheckedContinuation<Void, Error>]
        lock.lock()
        let waitingIDs = registrations.compactMap { id, registration in
            if case .waiting = registration { return id }
            return nil
        }
        pending = waitingIDs.compactMap { id in
            guard case let .some(.waiting(continuation)) = registrations[id] else { return nil }
            registrations[id] = .completed
            return continuation
        }
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    private func register(_ continuation: CheckedContinuation<Void, Error>, id: UUID) {
        onBeforeRegistrationLock?()

        let wasCancelled: Bool
        let onSleep: (() -> Void)?
        lock.lock()
        invocationCountStorage += 1
        if case .some(.cancelledBeforeRegistration) = registrations[id] {
            registrations[id] = .completed
            wasCancelled = true
        } else {
            registrations[id] = .waiting(continuation)
            wasCancelled = false
        }
        onSleep = self.onSleep
        lock.unlock()

        onSleep?()
        if wasCancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        switch registrations[id] {
        case let .some(.waiting(waiting)):
            registrations[id] = .completed
            continuation = waiting
        case .some(.completed), .some(.cancelledBeforeRegistration):
            continuation = nil
        case .none:
            registrations[id] = .cancelledBeforeRegistration
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(id: UUID) {
        lock.lock()
        registrations.removeValue(forKey: id)
        lock.unlock()
    }
}

private actor ControlledDraftPersistence: DraftPersistence {
    enum TestError: Error {
        case restoreFailed
    }

    enum Mutation: Equatable {
        case save(String)
        case clear
    }

    private var draftText: String?
    private let restoreFails: Bool
    private var mutationsStorage: [Mutation] = []
    private var completedMutationCount = 0
    private var blockNextMutation = false
    private var blockedMutationContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var mutationCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(draftText: String? = nil, restoreFails: Bool = false) {
        self.draftText = draftText
        self.restoreFails = restoreFails
    }

    func fetchDraftText(for conversationHash: Data) async throws -> String? {
        if restoreFails {
            throw TestError.restoreFailed
        }
        return draftText
    }

    func currentDraftText() -> String? {
        draftText
    }

    func saveDraft(_ content: String, for conversationHash: Data) async throws {
        mutationsStorage.append(.save(content))
        await blockIfRequested()
        draftText = content
        notifyMutationCompleted()
    }

    func clearDraft(for conversationHash: Data) async throws {
        mutationsStorage.append(.clear)
        await blockIfRequested()
        draftText = nil
        notifyMutationCompleted()
    }

    func arrangeToBlockNextMutation() {
        blockNextMutation = true
    }

    func waitUntilMutationIsBlocked() async {
        if blockedMutationContinuation != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func unblockMutation() {
        let continuation = blockedMutationContinuation
        blockedMutationContinuation = nil
        continuation?.resume()
    }

    func waitForMutationCount(_ count: Int) async {
        if completedMutationCount >= count { return }
        await withCheckedContinuation { mutationCountWaiters.append((count, $0)) }
    }

    func mutations() -> [Mutation] {
        mutationsStorage
    }

    private func blockIfRequested() async {
        guard blockNextMutation else { return }
        blockNextMutation = false
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { blockedMutationContinuation = $0 }
    }

    private func notifyMutationCompleted() {
        completedMutationCount += 1
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in mutationCountWaiters {
            if completedMutationCount >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        mutationCountWaiters = remaining
    }
}

private final class LockedCancellationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return valueStorage
    }

    func store(_ value: Bool) {
        lock.lock()
        valueStorage = value
        lock.unlock()
    }
}

@MainActor
private final class RecordingDraftAutosave: DraftAutosaving {
    enum Event: Equatable {
        case restore
        case textChanged(String)
        case clear
        case flush(String)
    }

    private(set) var events: [Event] = []
    let restoredText: String?

    init(restoredText: String?) {
        self.restoredText = restoredText
    }

    func restore() async throws -> String? {
        events.append(.restore)
        return restoredText
    }

    func textChanged(_ text: String) {
        events.append(.textChanged(text))
    }

    func flush(_ text: String) async {
        events.append(.flush(text))
    }

    func clearImmediately() {
        events.append(.clear)
    }
}

@MainActor
final class DraftAutosaveControllerTests: XCTestCase {
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-autosave-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
    }

    private func makeController(
        repository: MessageRepository,
        conversationHash: Data,
        sleeper: ControlledDraftSleeper
    ) -> DraftAutosaveController {
        DraftAutosaveController(
            repository: repository,
            conversationHash: conversationHash,
            debounceDuration: .seconds(30),
            sleeper: sleeper.sleep(for:)
        )
    }

    private func makeController(
        persistence: any DraftPersistence,
        conversationHash: Data,
        sleeper: ControlledDraftSleeper
    ) -> DraftAutosaveController {
        DraftAutosaveController(
            persistence: persistence,
            conversationHash: conversationHash,
            debounceDuration: .seconds(30),
            sleeper: sleeper.sleep(for:)
        )
    }

    private func draftChangeExpectation(for conversationHash: Data) -> (XCTestExpectation, NSObjectProtocol) {
        let changed = expectation(description: "Draft mutation committed")
        changed.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(
            forName: MessageRepository.draftChangedNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?[MessageRepository.conversationHashUserInfoKey] as? Data == conversationHash else {
                return
            }
            changed.fulfill()
        }
        return (changed, observer)
    }

    func testRapidEditsPersistOnlyLatestText() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0xA1, count: 16)
        let sleeper = ControlledDraftSleeper()
        let firstSleepStarted = expectation(description: "First debounce started")
        let secondSleepStarted = expectation(description: "Replacement debounce started")
        sleeper.onSleep = {
            if sleeper.invocationCount == 1 {
                firstSleepStarted.fulfill()
            } else if sleeper.invocationCount == 2 {
                secondSleepStarted.fulfill()
            }
        }
        let controller = makeController(
            repository: repository,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        try await repository.ensureConversation(conversationHash, displayName: nil)
        let (changed, observer) = draftChangeExpectation(for: conversationHash)
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.textChanged("older")
        await fulfillment(of: [firstSleepStarted], timeout: 1)
        controller.textChanged("latest")
        await fulfillment(of: [secondSleepStarted], timeout: 1)
        sleeper.resumeAll()
        await fulfillment(of: [changed], timeout: 1)

        let stored = try await repository.fetchDraft(for: conversationHash)
        XCTAssertEqual(stored?.content, "latest")
    }

    func testFlushPersistsImmediatelyWithoutWaitingForDebounce() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0xA2, count: 16)
        let sleeper = ControlledDraftSleeper()
        let sleepStarted = expectation(description: "Debounce started")
        sleeper.onSleep = { sleepStarted.fulfill() }
        let controller = makeController(
            repository: repository,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        try await repository.ensureConversation(conversationHash, displayName: nil)

        controller.textChanged("pending")
        await fulfillment(of: [sleepStarted], timeout: 1)
        await controller.flush("flushed now")

        let stored = try await repository.fetchDraft(for: conversationHash)
        XCTAssertEqual(stored?.content, "flushed now")
    }

    func testFlushOfBlankTextDeletesDraft() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0xA3, count: 16)
        let sleeper = ControlledDraftSleeper()
        let controller = makeController(
            repository: repository,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        try await repository.ensureConversation(conversationHash, displayName: nil)
        try await repository.saveDraft("existing", for: conversationHash)

        await controller.flush(" \t\n ")

        let stored = try await repository.fetchDraft(for: conversationHash)
        XCTAssertNil(stored)
    }

    func testClearCancelsPendingSaveAndDraftStaysAbsent() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0xA4, count: 16)
        let sleeper = ControlledDraftSleeper()
        let sleepStarted = expectation(description: "Debounce started")
        sleeper.onSleep = { sleepStarted.fulfill() }
        let controller = makeController(
            repository: repository,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        try await repository.ensureConversation(conversationHash, displayName: nil)
        try await repository.saveDraft("existing", for: conversationHash)
        let (cleared, observer) = draftChangeExpectation(for: conversationHash)
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.textChanged("must not survive")
        await fulfillment(of: [sleepStarted], timeout: 1)
        controller.clearImmediately()
        await fulfillment(of: [cleared], timeout: 1)
        sleeper.resumeAll()

        let stored = try await repository.fetchDraft(for: conversationHash)
        XCTAssertNil(stored)
    }

    func testOldDelayedSaveCannotOverwriteNewerText() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0xA5, count: 16)
        let sleeper = ControlledDraftSleeper()
        let sleepStarted = expectation(description: "Old debounce started")
        sleeper.onSleep = { sleepStarted.fulfill() }
        let controller = makeController(
            repository: repository,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        try await repository.ensureConversation(conversationHash, displayName: nil)

        controller.textChanged("stale delayed text")
        await fulfillment(of: [sleepStarted], timeout: 1)
        await controller.flush("newer text")
        sleeper.resumeAll()

        let stored = try await repository.fetchDraft(for: conversationHash)
        XCTAssertEqual(stored?.content, "newer text")
    }

    func testEnqueuedDelayedSaveCompletesBeforeLaterClear() async throws {
        let conversationHash = Data(repeating: 0xA7, count: 16)
        let persistence = ControlledDraftPersistence()
        let sleeper = ControlledDraftSleeper()
        let sleepStarted = expectation(description: "Debounce started")
        sleeper.onSleep = { sleepStarted.fulfill() }
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        await persistence.arrangeToBlockNextMutation()

        controller.textChanged("stale but already enqueued")
        await fulfillment(of: [sleepStarted], timeout: 1)
        sleeper.resumeAll()
        await persistence.waitUntilMutationIsBlocked()
        let mutationsBeforeClear = await persistence.mutations()
        XCTAssertEqual(mutationsBeforeClear, [.save("stale but already enqueued")])

        controller.clearImmediately()
        await persistence.unblockMutation()
        await persistence.waitForMutationCount(2)

        let mutationsAfterClear = await persistence.mutations()
        let finalDraft = try await persistence.fetchDraftText(for: conversationHash)
        XCTAssertEqual(mutationsAfterClear, [.save("stale but already enqueued"), .clear])
        XCTAssertNil(finalDraft)
    }

    func testClearCompletesBeforeImmediatelyFollowingFlush() async throws {
        let conversationHash = Data(repeating: 0xA8, count: 16)
        let persistence = ControlledDraftPersistence(draftText: "existing")
        let sleeper = ControlledDraftSleeper()
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        await persistence.arrangeToBlockNextMutation()
        let flushed = expectation(description: "Flush completed durably")

        controller.clearImmediately()
        Task { @MainActor in
            await controller.flush("newer edit")
            flushed.fulfill()
        }

        await persistence.waitUntilMutationIsBlocked()
        let mutationsWhileClearBlocked = await persistence.mutations()
        XCTAssertEqual(mutationsWhileClearBlocked, [.clear])
        await persistence.unblockMutation()
        await fulfillment(of: [flushed], timeout: 1)

        let finalMutations = await persistence.mutations()
        let finalDraft = try await persistence.fetchDraftText(for: conversationHash)
        XCTAssertEqual(finalMutations, [.clear, .save("newer edit")])
        XCTAssertEqual(finalDraft, "newer edit")
    }

    func testSleeperCancellationBeforeRegistrationDoesNotHangOrLeak() async {
        let sleeper = ControlledDraftSleeper()
        let registrationReached = expectation(description: "Registration race window reached")
        let sleepFinished = expectation(description: "Cancelled sleep finished")
        let allowRegistration = DispatchSemaphore(value: 0)
        let result = LockedCancellationResult()
        sleeper.onBeforeRegistrationLock = {
            registrationReached.fulfill()
            allowRegistration.wait()
        }

        let task = Task.detached {
            do {
                try await sleeper.sleep(for: .seconds(30))
                result.store(false)
            } catch is CancellationError {
                result.store(true)
            } catch {
                result.store(false)
            }
            sleepFinished.fulfill()
        }

        await fulfillment(of: [registrationReached], timeout: 1)
        task.cancel()
        allowRegistration.signal()
        await fulfillment(of: [sleepFinished], timeout: 1)

        XCTAssertEqual(result.value, true)
        XCTAssertEqual(sleeper.invocationCount, 1)
        XCTAssertEqual(sleeper.pendingRegistrationCount, 0)
    }

    func testRestoreReturnsStoredTextWithoutSchedulingAnotherWrite() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let conversationHash = Data(repeating: 0xA6, count: 16)
        let sleeper = ControlledDraftSleeper()
        let controller = makeController(
            repository: repository,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        try await repository.ensureConversation(conversationHash, displayName: nil)
        try await repository.saveDraft("restored exactly", for: conversationHash)

        let restored = try await controller.restore()

        XCTAssertEqual(restored, "restored exactly")
        XCTAssertEqual(sleeper.invocationCount, 0)
    }

    func testInitialDraftIsAppliedBeforeConversationBecomesInteractive() async throws {
        var events: [String] = []
        var composerText = ""
        var isInteractive = false

        let outcome = try await MessagingDraftBootstrap.prepare(
            loadMessages: {
                events.append("messages loaded")
            },
            restoreDraft: {
                events.append("draft restored")
                return "unfinished message"
            }
        )
        try MessagingDraftBootstrap.commit(
            outcome,
            applyRestoredText: { restoredText in
                composerText = restoredText
                events.append("draft applied")
            },
            handleRestoreFailure: {
                XCTFail("Restore should succeed")
            },
            publishConversation: {
                isInteractive = true
                events.append("conversation published")
            }
        )

        XCTAssertEqual(composerText, "unfinished message")
        XCTAssertTrue(isInteractive)
        XCTAssertEqual(
            events,
            ["messages loaded", "draft restored", "draft applied", "conversation published"]
        )
    }

    func testProgrammaticRestoreDoesNotScheduleRedundantAutosave() async throws {
        let conversationHash = Data(repeating: 0xA9, count: 16)
        let persistence = ControlledDraftPersistence(draftText: "restored without a write")
        let sleeper = ControlledDraftSleeper()
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        let lifecycle = MessagingComposerLifecycle(autosave: controller)
        var composerText = ""

        let outcome = try await MessagingDraftBootstrap.prepare(
            loadMessages: {},
            restoreDraft: { try await lifecycle.restore() }
        )
        try MessagingDraftBootstrap.commit(
            outcome,
            applyRestoredText: {
                lifecycle.applyProgrammaticRestore($0) { composerText = $0 }
            },
            handleRestoreFailure: {
                XCTFail("Restore should succeed")
            },
            publishConversation: {}
        )

        XCTAssertEqual(composerText, "restored without a write")
        XCTAssertTrue(lifecycle.draftPersistenceReady)
        XCTAssertEqual(sleeper.invocationCount, 0)
        let mutations = await persistence.mutations()
        XCTAssertTrue(mutations.isEmpty)
    }

    func testProductionComposerLifecycleRoutesEveryComposerBoundaryInOrder() async throws {
        let autosave = RecordingDraftAutosave(restoredText: "restored")
        let lifecycle = MessagingComposerLifecycle(autosave: autosave)
        var composerText = ""

        let restored = try await lifecycle.restore()
        lifecycle.applyProgrammaticRestore(restored ?? "") { composerText = $0 }
        XCTAssertEqual(composerText, "restored")
        XCTAssertEqual(autosave.events, [.restore])

        lifecycle.userEdited("binding edit") { composerText = $0 }
        XCTAssertEqual(composerText, "binding edit")
        XCTAssertEqual(autosave.events, [.restore, .textChanged("binding edit")])

        lifecycle.clearForSend {
            XCTAssertEqual(autosave.events.last, .clear, "Persistence invalidation must precede UI clear")
            composerText = ""
        }
        XCTAssertEqual(composerText, "")

        await lifecycle.navigationFlush("navigation value")
        await lifecycle.backgroundFlush("background value")
        XCTAssertEqual(
            autosave.events,
            [
                .restore,
                .textChanged("binding edit"),
                .clear,
                .flush("navigation value"),
                .flush("background value")
            ]
        )
    }

    func testSendClearInvalidatesPendingTypedSave() async {
        let conversationHash = Data(repeating: 0xAA, count: 16)
        let persistence = ControlledDraftPersistence(draftText: "previous draft")
        let sleeper = ControlledDraftSleeper()
        let debounceStarted = expectation(description: "Typed autosave is pending")
        sleeper.onSleep = { debounceStarted.fulfill() }
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        let lifecycle = MessagingComposerLifecycle(autosave: controller)
        lifecycle.applyProgrammaticRestore("previous draft") { _ in }

        lifecycle.userEdited("message being sent") { _ in }
        await fulfillment(of: [debounceStarted], timeout: 1)
        var composerWasCleared = false
        lifecycle.clearForSend {
            composerWasCleared = true
        }
        await persistence.waitForMutationCount(1)
        sleeper.resumeAll()

        let mutations = await persistence.mutations()
        let stored = try? await persistence.fetchDraftText(for: conversationHash)
        XCTAssertEqual(mutations, [.clear])
        XCTAssertNil(stored)
        XCTAssertTrue(composerWasCleared)
    }

    func testNavigationFlushUsesLatestComposerValue() async {
        let conversationHash = Data(repeating: 0xAB, count: 16)
        let persistence = ControlledDraftPersistence()
        let sleeper = ControlledDraftSleeper()
        let debounceStarted = expectation(description: "Older autosave is pending")
        sleeper.onSleep = { debounceStarted.fulfill() }
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        let lifecycle = MessagingComposerLifecycle(autosave: controller)
        lifecycle.applyProgrammaticRestore("") { _ in }

        lifecycle.userEdited("older value") { _ in }
        await fulfillment(of: [debounceStarted], timeout: 1)
        await lifecycle.navigationFlush("latest value at navigation")
        sleeper.resumeAll()

        let mutations = await persistence.mutations()
        let stored = try? await persistence.fetchDraftText(for: conversationHash)
        XCTAssertEqual(mutations, [.save("latest value at navigation")])
        XCTAssertEqual(stored, "latest value at navigation")
    }

    func testBackgroundFlushUsesLatestComposerValue() async {
        let conversationHash = Data(repeating: 0xAC, count: 16)
        let persistence = ControlledDraftPersistence()
        let sleeper = ControlledDraftSleeper()
        let debounceStarted = expectation(description: "Visible-screen autosave is pending")
        sleeper.onSleep = { debounceStarted.fulfill() }
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        let lifecycle = MessagingComposerLifecycle(autosave: controller)
        lifecycle.applyProgrammaticRestore("") { _ in }

        lifecycle.userEdited("value before backgrounding") { _ in }
        await fulfillment(of: [debounceStarted], timeout: 1)
        await lifecycle.backgroundFlush("latest value at background")
        sleeper.resumeAll()

        let mutations = await persistence.mutations()
        let stored = try? await persistence.fetchDraftText(for: conversationHash)
        XCTAssertEqual(mutations, [.save("latest value at background")])
        XCTAssertEqual(stored, "latest value at background")
    }

    func testCancellationBeforeBootstrapCommitDoesNotApplyHandleFailureOrPublishAndCanRetry() async throws {
        let conversationHash = Data(repeating: 0xAD, count: 16)
        let persistence = ControlledDraftPersistence(draftText: "durable draft")
        let sleeper = ControlledDraftSleeper()
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        let lifecycle = MessagingComposerLifecycle(autosave: controller)
        var composerText = "unchanged"
        var publishCount = 0
        var failureCount = 0

        let cancelledAttempt = Task { @MainActor in
            let outcome = try await MessagingDraftBootstrap.prepare(
                loadMessages: {},
                restoreDraft: { try await lifecycle.restore() }
            )
            withUnsafeCurrentTask { $0?.cancel() }
            try MessagingDraftBootstrap.commit(
                outcome,
                applyRestoredText: { composerText = $0 },
                handleRestoreFailure: { failureCount += 1 },
                publishConversation: { publishCount += 1 }
            )
        }

        do {
            try await cancelledAttempt.value
            XCTFail("Cancelled bootstrap should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(composerText, "unchanged")
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(failureCount, 0)
        XCTAssertFalse(lifecycle.draftPersistenceReady)

        let retryOutcome = try await MessagingDraftBootstrap.prepare(
            loadMessages: {},
            restoreDraft: { try await lifecycle.restore() }
        )
        try MessagingDraftBootstrap.commit(
            retryOutcome,
            applyRestoredText: {
                lifecycle.applyProgrammaticRestore($0) { composerText = $0 }
            },
            handleRestoreFailure: { failureCount += 1 },
            publishConversation: { publishCount += 1 }
        )

        XCTAssertEqual(composerText, "durable draft")
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(failureCount, 0)
        XCTAssertTrue(lifecycle.draftPersistenceReady)
    }

    func testCancellationInsideBootstrapSuccessApplyStillPublishesWholeCommit() async throws {
        var composerText = "unchanged"
        var failureCount = 0
        var publishCount = 0
        var wasCancelledWhenPublished = false

        let attempt = Task { @MainActor in
            try MessagingDraftBootstrap.commit(
                .restored("restored draft"),
                applyRestoredText: {
                    composerText = $0
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                handleRestoreFailure: { failureCount += 1 },
                publishConversation: {
                    wasCancelledWhenPublished = Task.isCancelled
                    publishCount += 1
                }
            )
        }

        try await attempt.value
        XCTAssertEqual(composerText, "restored draft")
        XCTAssertEqual(failureCount, 0)
        XCTAssertEqual(publishCount, 1)
        XCTAssertTrue(wasCancelledWhenPublished)
    }

    func testCancellationInsideBootstrapFailureHandlerStillPublishesWholeCommit() async throws {
        var applyCount = 0
        var failureCount = 0
        var publishCount = 0
        var wasCancelledWhenPublished = false

        let attempt = Task { @MainActor in
            try MessagingDraftBootstrap.commit(
                .restoreFailed,
                applyRestoredText: { _ in applyCount += 1 },
                handleRestoreFailure: {
                    failureCount += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                publishConversation: {
                    wasCancelledWhenPublished = Task.isCancelled
                    publishCount += 1
                }
            )
        }

        try await attempt.value
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(publishCount, 1)
        XCTAssertTrue(wasCancelledWhenPublished)
    }

    func testRestoreFailureGatesLifecycleClearAndFlushUntilExplicitEdit() async throws {
        let conversationHash = Data(repeating: 0xAE, count: 16)
        let persistence = ControlledDraftPersistence(
            draftText: "unread durable draft",
            restoreFails: true
        )
        let sleeper = ControlledDraftSleeper()
        let controller = makeController(
            persistence: persistence,
            conversationHash: conversationHash,
            sleeper: sleeper
        )
        let lifecycle = MessagingComposerLifecycle(autosave: controller)
        var composerText = ""
        var published = false

        let outcome = try await MessagingDraftBootstrap.prepare(
            loadMessages: {},
            restoreDraft: { try await lifecycle.restore() }
        )
        try MessagingDraftBootstrap.commit(
            outcome,
            applyRestoredText: { _ in XCTFail("Failed restore must not apply empty text") },
            handleRestoreFailure: { lifecycle.restoreFailed() },
            publishConversation: { published = true }
        )

        XCTAssertTrue(published)
        XCTAssertFalse(lifecycle.draftPersistenceReady)
        await lifecycle.navigationFlush(composerText)
        await lifecycle.backgroundFlush(composerText)
        lifecycle.clearForSend { composerText = "" }
        let gatedMutations = await persistence.mutations()
        let preservedDraft = await persistence.currentDraftText()
        XCTAssertEqual(gatedMutations, [])
        XCTAssertEqual(preservedDraft, "unread durable draft")

        lifecycle.userEdited("explicit replacement") { composerText = $0 }
        XCTAssertTrue(lifecycle.draftPersistenceReady)
        await lifecycle.navigationFlush(composerText)

        let replacementMutations = await persistence.mutations()
        let replacementDraft = await persistence.currentDraftText()
        XCTAssertEqual(replacementMutations, [.save("explicit replacement")])
        XCTAssertEqual(replacementDraft, "explicit replacement")
    }
}
