//
//  BackgroundPropagationSyncTests.swift
//  ColumbaAppTests
//

import XCTest
import RNSAPI
@testable import ColumbaApp

@MainActor
final class BackgroundPropagationSyncTests: XCTestCase {
    func testSchedulePolicyDisablesRefreshWhenPeriodicSyncIsOff() {
        XCTAssertNil(
            BackgroundPropagationSchedulePolicy.nextDelay(
                periodicSyncEnabled: false,
                userInterval: 3_600
            )
        )
    }

    func testSchedulePolicyFloorsUserIntervalAtFifteenMinutes() {
        XCTAssertEqual(
            BackgroundPropagationSchedulePolicy.nextDelay(
                periodicSyncEnabled: true,
                userInterval: 60
            ),
            15 * 60
        )
        XCTAssertEqual(
            BackgroundPropagationSchedulePolicy.nextDelay(
                periodicSyncEnabled: true,
                userInterval: 30 * 60
            ),
            30 * 60
        )
    }

    func testIOSBackgroundRefreshIsTheOnlyPeriodicSyncScheduler() {
        let manager = PropagationNodeManager(appServices: AppServices())
        manager.periodicSyncEnabled = true
        manager.syncInterval = 900

        manager.startPeriodicSync()
        defer { manager.stopPeriodicSync() }

        XCTAssertFalse(manager.hasInProcessPeriodicSyncTaskForTesting)
    }

    func testNormalNotificationPolicyHonorsEnabledAndFavoritesOnlySettings() {
        let suiteName = "BackgroundPropagationSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "notifications_enabled")
        XCTAssertFalse(NotificationService.shouldPostMessageNotification(isFavorite: true, defaults: defaults))

        defaults.set(true, forKey: "notifications_enabled")
        defaults.set(true, forKey: "notify_received_message")
        defaults.set(true, forKey: "notify_received_message_favorite")
        XCTAssertFalse(NotificationService.shouldPostMessageNotification(isFavorite: false, defaults: defaults))
        XCTAssertTrue(NotificationService.shouldPostMessageNotification(isFavorite: true, defaults: defaults))

        defaults.set(false, forKey: "notify_received_message_favorite")
        XCTAssertTrue(NotificationService.shouldPostMessageNotification(isFavorite: false, defaults: defaults))

        defaults.set(false, forKey: "notify_received_message")
        XCTAssertFalse(NotificationService.shouldPostMessageNotification(isFavorite: true, defaults: defaults))
    }

    func testRepositoryInsertionCursorReturnsOnlyNewInboundMessages() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-bg-sync-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let oldMessage = makeMessage(idByte: 0x01, incoming: true)
        try await repository.saveMessage(oldMessage)
        let cursor = try await repository.captureMessageInsertionCursor()

        try await repository.saveMessage(oldMessage)
        let newInbound = makeMessage(idByte: 0x02, incoming: true)
        let newOutbound = makeMessage(idByte: 0x03, incoming: false)
        try await repository.saveMessage(newInbound)
        try await repository.saveMessage(newOutbound)

        let messages = try await repository.fetchIncomingMessagesInserted(after: cursor)

        XCTAssertEqual(messages.map(\.hash), [newInbound.hash])
    }

    func testRepositoryTotalUnreadCountIgnoresNotificationHistory() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-bg-badge-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let repository = try MessageRepository(grdbPath: databaseURL.path)
        try await repository.saveMessage(makeMessage(idByte: 0x21, incoming: true))
        try await repository.saveMessage(makeMessage(idByte: 0x22, incoming: true))
        try await repository.saveMessage(makeMessage(idByte: 0x23, incoming: false))

        let unreadCount = try await repository.totalUnreadCount()
        XCTAssertEqual(unreadCount, 2)
    }

    func testNotificationBadgeUsesDurableUnreadCount() {
        XCTAssertEqual(NotificationService.badgeValue(totalUnreadCount: 3), NSNumber(value: 3))
        XCTAssertEqual(NotificationService.badgeValue(totalUnreadCount: -1), NSNumber(value: 0))
    }

    func testPendingRequestDiagnosticsAreDeterministicAndPrivacySafe() {
        let summary = BackgroundRefreshDiagnosticFormatter.pendingRequests(
            [
                .init(
                    identifier: BackgroundPropagationRefreshScheduler.taskIdentifier,
                    earliestBeginDate: Date(timeIntervalSince1970: 1_722_240_900)
                )
            ]
        )

        XCTAssertEqual(
            summary,
            "count=1 [network.columba.Columba.sync earliest=2024-07-29T08:15:00Z]"
        )
    }

    func testRuntimeDiagnosticsIncludeSchedulingConditions() {
        let summary = BackgroundRefreshDiagnosticFormatter.runtime(
            processID: 42,
            backgroundRefreshStatus: "denied",
            lowPowerModeEnabled: true,
            thermalState: "serious",
            protectedDataAvailable: false,
            sceneStates: ["background"]
        )

        XCTAssertEqual(
            summary,
            "pid=42 refresh=denied lowPower=true thermal=serious protectedData=false scenes=background"
        )
    }

    func testBackgroundNotificationClassifierRejectsTelemetryAndCeaseControls() {
        let normal = makeMessage(idByte: 0x11, incoming: true)
        let telemetry = makeMessage(
            idByte: 0x12,
            incoming: true,
            content: Data(),
            fields: [LXMessage.FIELD_TELEMETRY: Data([0x01])]
        )
        let cease = makeMessage(
            idByte: 0x13,
            incoming: true,
            content: Data(),
            fields: [LXMessage.FIELD_COLUMBA_META: Data("{\"cease\":true}".utf8)]
        )

        XCTAssertTrue(IncomingMessageHandler.isUserNotifiableMessage(normal))
        XCTAssertFalse(IncomingMessageHandler.isUserNotifiableMessage(telemetry))
        XCTAssertFalse(IncomingMessageHandler.isUserNotifiableMessage(cease))
    }

    func testBuiltAppDeclaresBackgroundRefreshRequirements() throws {
        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        let identifiers = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )

        XCTAssertTrue(modes.contains("fetch"))
        XCTAssertTrue(identifiers.contains(BackgroundPropagationRefreshScheduler.taskIdentifier))
    }

    func testWorkflowNotifiesEachMessageInsertedDuringSuccessfulSync() async {
        var events: [String] = []
        let workflow = BackgroundPropagationSyncWorkflow<String>(
            captureInsertionCursor: {
                events.append("capture")
                return 42
            },
            sync: {
                events.append("sync")
                return true
            },
            messagesInsertedAfter: { cursor in
                events.append("load:\(cursor)")
                return ["first", "second"]
            },
            notify: { message in
                events.append("notify:\(message)")
            }
        )

        let succeeded = await workflow.run()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            events,
            ["capture", "sync", "load:42", "notify:first", "notify:second"]
        )
    }

    func testWorkflowDoesNotLoadOrNotifyWhenSyncFails() async {
        var loaded = false
        var notified = false
        let workflow = BackgroundPropagationSyncWorkflow<String>(
            captureInsertionCursor: { 7 },
            sync: { false },
            messagesInsertedAfter: { _ in
                loaded = true
                return ["unexpected"]
            },
            notify: { _ in notified = true }
        )

        let succeeded = await workflow.run()

        XCTAssertFalse(succeeded)
        XCTAssertFalse(loaded)
        XCTAssertFalse(notified)
    }

    func testTaskReceivedBeforeHandlerRunsAfterHandlerInstallation() async {
        let coordinator = BackgroundRefreshTaskCoordinator()
        let task = FakeBackgroundRefreshTask()

        coordinator.receive(task)
        XCTAssertTrue(task.completions.isEmpty)

        coordinator.installHandler { true }
        await task.waitForCompletion()

        XCTAssertEqual(task.completions, [true])
    }

    func testExpirationCompletesTaskOnceAndSuppressesLateSuccess() async {
        let coordinator = BackgroundRefreshTaskCoordinator()
        let task = FakeBackgroundRefreshTask()
        let gate = AsyncGate()

        coordinator.installHandler {
            await gate.wait()
            return true
        }
        coordinator.receive(task)

        task.expirationHandler?()
        await task.waitForCompletion()
        gate.open()
        await Task.yield()

        XCTAssertEqual(task.completions, [false])
    }

    private func makeMessage(
        idByte: UInt8,
        incoming: Bool,
        content: Data? = nil,
        fields: [UInt8: Any]? = nil
    ) -> LXMessage {
        let message = LXMessage(
            destinationHash: Data(repeating: 0xDD, count: 16),
            sourceIdentity: nil,
            content: content ?? Data("message-\(idByte)".utf8),
            title: Data(),
            fields: fields,
            desiredMethod: incoming ? .propagated : .direct
        )
        message.sourceHash = Data(repeating: 0xAA, count: 16)
        message.hash = Data(repeating: idByte, count: 16)
        message.timestamp = Date().timeIntervalSince1970
        message.incoming = incoming
        message.state = incoming ? .received : .sent
        message.method = incoming ? .propagated : .direct
        return message
    }
}

@MainActor
private final class FakeBackgroundRefreshTask: BackgroundRefreshTaskHandle {
    var expirationHandler: (() -> Void)?
    private(set) var completions: [Bool] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func setTaskCompleted(success: Bool) {
        completions.append(success)
        continuation?.resume()
        continuation = nil
    }

    func waitForCompletion() async {
        if !completions.isEmpty { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
