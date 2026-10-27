//
//  BackgroundPropagationSyncTests.swift
//  ColumbaAppTests
//

import XCTest
import GRDB
import UIKit
import RNSAPI
@testable import ColumbaApp

@MainActor
final class BackgroundPropagationSyncTests: XCTestCase {
    func testDatabaseSuspensionKeepsAccessUntilLastOverlappingGrantEnds() {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let first = controller.beginBackgroundAccess()
        let second = controller.beginBackgroundAccess()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(notifications.accessStates, [false, true])

        controller.endBackgroundAccess(first)
        controller.endBackgroundAccess(first)
        controller.endBackgroundAccess(UUID())
        XCTAssertEqual(notifications.accessStates, [false, true])

        controller.endBackgroundAccess(second)
        controller.endBackgroundAccess(second)
        XCTAssertEqual(notifications.accessStates, [false, true, false])
    }

    func testForegroundTransitionDuringBackgroundGrantKeepsDatabaseUsable() {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: true, notificationCenter: notifications.center
        )
        let first = controller.beginBackgroundAccess()
        controller.setForeground(false)
        XCTAssertEqual(notifications.accessStates, [true])
        controller.endBackgroundAccess(first)
        XCTAssertEqual(notifications.accessStates, [true, false])

        let second = controller.beginBackgroundAccess()
        controller.setForeground(true)
        controller.endBackgroundAccess(second)
        XCTAssertEqual(notifications.accessStates, [true, false, true])
        controller.setForeground(false)
        XCTAssertEqual(notifications.accessStates, [true, false, true, false])
    }

    func testDatabaseStartupWaitsForBackgroundGrantOrForeground() async throws {
        for useGrant in [true, false] {
            let notifications = DatabaseSuspensionNotifications()
            let controller = DatabaseSuspensionController(
                isForeground: false, notificationCenter: notifications.center
            )
            let started = expectation(description: "startup waiting")
            var returned = false
            let startup = Task { @MainActor in
                started.fulfill()
                try await controller.waitUntilAccessAllowed()
                returned = true
            }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertFalse(returned)

            if useGrant {
                let token = controller.beginBackgroundAccess()
                try await startup.value
                controller.endBackgroundAccess(token)
                XCTAssertEqual(notifications.accessStates, [false, true, false])
            } else {
                controller.setForeground(true)
                try await startup.value
                XCTAssertEqual(notifications.accessStates, [false, true])
            }
            XCTAssertTrue(returned)
        }
    }

    func testDatabaseStartupRechecksGrantThatExpiresBeforeWaiterResumes() async throws {
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: NotificationCenter()
        )
        let started = expectation(description: "startup waiting")
        var returned = false
        let startup = Task { @MainActor in
            started.fulfill()
            try await controller.waitUntilAccessAllowed()
            returned = true
        }
        await fulfillment(of: [started], timeout: 2)

        let token = controller.beginBackgroundAccess()
        controller.endBackgroundAccess(token)
        // Let the resumed continuation re-enter the suspended gate. It must
        // not treat the now-expired grant as permission to create a pool.
        let checked = expectation(description: "expired grant checked")
        Task { @MainActor in
            XCTAssertFalse(returned)
            checked.fulfill()
        }
        await fulfillment(of: [checked], timeout: 2)
        controller.setForeground(true)
        try await startup.value
        XCTAssertTrue(returned)
    }

    func testDatabaseStartupCancellationDoesNotWaitForPermissionOrResumeTwice() async {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let started = expectation(description: "startup waiting")
        let startup = Task { @MainActor in
            started.fulfill()
            try await controller.waitUntilAccessAllowed()
        }
        await fulfillment(of: [started], timeout: 2)
        startup.cancel()

        do {
            try await startup.value
            XCTFail("Canceled startup must not open the database")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // Resuming after cancellation must not resume the removed continuation.
        controller.setForeground(true)
        XCTAssertEqual(notifications.accessStates, [false, true])
    }

    func testAlreadyCanceledDatabaseStartupDoesNotUseForegroundPermission() async {
        let controller = DatabaseSuspensionController(
            isForeground: true, notificationCenter: NotificationCenter()
        )
        let startup = Task { @MainActor in
            try await controller.waitUntilAccessAllowed()
        }
        startup.cancel()

        do {
            try await startup.value
            XCTFail("Permission must not override cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

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

    func testIOSManagerDoesNotDuplicateNodeOwnedPeriodicScheduler() {
        let manager = PropagationNodeManager(appServices: AppServices())
        manager.periodicSyncEnabled = true
        manager.syncInterval = 900

        manager.startPeriodicSync()
        defer { manager.stopPeriodicSync() }

        XCTAssertFalse(manager.hasInProcessPeriodicSyncTaskForTesting)
    }

    func testCancellationOnlyAffectsTheMatchingActiveSync() async {
        let request = ControlledPropagationSync()
        let manager = PropagationNodeManager(
            appServices: AppServices(),
            propagationSyncRequest: { timeout in await request.run(timeout: timeout) },
            propagationSyncCancellation: { request.cancel() }
        )
        manager.selectedNodeHash = Data(repeating: 0x42, count: 16)
        let firstID = UUID()
        let secondID = UUID()

        let firstStarted = expectation(description: "first sync started")
        request.started = firstStarted
        let first = Task { await manager.syncNow(operationID: firstID) }
        await fulfillment(of: [firstStarted], timeout: 2)
        await manager.cancelActiveSync(operationID: firstID)
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        XCTAssertEqual(manager.syncState.errorDescription, "cancelled")
        XCTAssertEqual(request.cancellations, 1)

        let secondStarted = expectation(description: "second sync started")
        request.started = secondStarted
        let second = Task { await manager.syncNow(operationID: secondID) }
        await fulfillment(of: [secondStarted], timeout: 2)
        await manager.cancelActiveSync(operationID: firstID)
        XCTAssertEqual(request.cancellations, 1)
        request.complete()
        let secondResult = await second.value
        XCTAssertTrue(secondResult, "A late cancellation must not interrupt a newer sync")
        XCTAssertEqual(manager.syncState.receivedMessages, 3)

        await manager.cancelActiveSync(operationID: secondID)
        XCTAssertEqual(request.cancellations, 1, "Completed operations must not cancel the backend")
    }

    func testNodeRetrievalScheduleTracksSelectionIntervalAndDisable() {
        var schedule = NodePropagationSchedule()
        let start = Date(timeIntervalSince1970: 1000)
        var config = PropagationSeamConfig(propagationNodeHash: Data([1]), stampCost: 0,
                                          syncInterval: 60, periodicSyncEnabled: true)
        XCTAssertFalse(schedule.shouldSync(config: config, now: start))
        XCTAssertFalse(schedule.shouldSync(config: config, now: start.addingTimeInterval(59)))
        XCTAssertTrue(schedule.shouldSync(config: config, now: start.addingTimeInterval(60)))
        XCTAssertFalse(schedule.shouldSync(config: config, now: start.addingTimeInterval(60)))
        config.syncInterval = 30
        XCTAssertFalse(schedule.shouldSync(config: config, now: start.addingTimeInterval(70)))
        XCTAssertTrue(schedule.shouldSync(config: config, now: start.addingTimeInterval(100)))
        config.periodicSyncEnabled = false
        XCTAssertFalse(schedule.shouldSync(config: config, now: start.addingTimeInterval(200)))
        config.periodicSyncEnabled = true
        XCTAssertFalse(schedule.shouldSync(config: config, now: start.addingTimeInterval(201)))
        config.propagationNodeHash = Data([2])
        XCTAssertFalse(schedule.shouldSync(config: config, now: start.addingTimeInterval(230)))
        XCTAssertTrue(schedule.shouldSync(config: config, now: start.addingTimeInterval(260)))
        XCTAssertFalse(schedule.shouldSync(config: nil, now: start.addingTimeInterval(400)))
        config.propagationNodeHash = nil
        XCTAssertFalse(schedule.shouldSync(config: config, now: start.addingTimeInterval(500)))
    }

    func testScheduledSuccessPublishesHistoryAndManagerCatchesUp() async {
        let group = "ScheduledSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: group)!
        defer { defaults.removePersistentDomain(forName: group) }
        let completion = Date(timeIntervalSince1970: 1234567)
        XCTAssertTrue(PropagationSyncStateSnapshot.publishSuccessfulResult(
            ["ok": true, "received_messages": 3], at: completion, group: group))
        XCTAssertEqual(defaults.double(forKey: "lastSyncTimestamp"), completion.timeIntervalSince1970)
        let snapshot = PropagationSyncStateSnapshot.loadFromAppGroup(group)
        XCTAssertEqual(snapshot?.phase, .complete)
        XCTAssertEqual(snapshot?.received, 3)
        XCTAssertEqual(snapshot?.lastSuccessfulSync, completion)

        // A fresh manager catches up even if it missed the Darwin notification.
        let manager = PropagationNodeManager(appServices: AppServices())
        manager.refreshLastSyncTime(group: group)
        XCTAssertEqual(manager.lastSyncTime, completion)
        XCTAssertEqual(manager.syncState.lastSync, completion)

        let failures: [[String: Any]?] = [nil, [:], ["ok": false, "reason": "no-node"]]
        for result in failures {
            XCTAssertFalse(PropagationSyncStateSnapshot.publishSuccessfulResult(
                result, at: completion.addingTimeInterval(60), group: group))
            XCTAssertEqual(PropagationSyncStateSnapshot.lastSuccessfulSync(in: group), completion)
            XCTAssertEqual(PropagationSyncStateSnapshot.loadFromAppGroup(group), snapshot)
        }
        XCTAssertTrue(PropagationSyncStateSnapshot.publishSuccessfulResult(
            ["ok": true, "received_messages": 0], at: completion.addingTimeInterval(120), group: group))
        manager.refreshLastSyncTime(group: group)
        XCTAssertEqual(manager.lastSyncTime, completion.addingTimeInterval(120))
    }

    func testLegacySyncSnapshotDecodesWithoutCompletionTime() throws {
        let data = Data(#"{"phase":"complete","progress":1,"received":2,"total":2}"#.utf8)
        let snapshot = try JSONDecoder().decode(PropagationSyncStateSnapshot.self, from: data)
        XCTAssertEqual(snapshot.received, 2)
        XCTAssertNil(snapshot.lastSuccessfulSync)
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

    func testRepositoryInsertionCursorSurvivesHighestRowDeletionAndRowIDReuse() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-bg-rowid-reuse-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let first = makeMessage(idByte: 0x11, incoming: true)
        let highest = makeMessage(idByte: 0x12, incoming: true)
        try await repository.saveMessage(first)
        try await repository.saveMessage(highest)
        let cursor = try await repository.captureMessageInsertionCursor()

        try await repository.deleteMessage(highest.hash)
        let replacement = makeMessage(idByte: 0x13, incoming: true)
        try await repository.saveMessage(replacement)

        let messages = try await repository.fetchIncomingMessagesInserted(after: cursor)
        XCTAssertEqual(messages.map(\.hash), [replacement.hash])
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
                    identifier: BackgroundPropagationTaskScheduler.refreshTaskIdentifier,
                    earliestBeginDate: Date(timeIntervalSince1970: 1_722_240_900)
                )
            ]
        )

        XCTAssertEqual(
            summary,
            "count=1 [network.columba.Columba.sync earliest=2024-07-29T08:15:00Z]"
        )
    }

    func testTaskKindsDeclareDistinctPermittedIdentifiers() {
        XCTAssertEqual(
            BackgroundPropagationTaskKind.refresh.taskIdentifier,
            "network.columba.Columba.sync"
        )
        XCTAssertEqual(
            BackgroundPropagationTaskKind.processing.taskIdentifier,
            "network.columba.Columba.sync-processing"
        )
        XCTAssertEqual(Set(BackgroundPropagationTaskKind.allCases.map(\.taskIdentifier)).count, 2)
    }

    func testSchedulePolicyAnchorsToLastCompletedSyncNotSubmitTime() {
        let lastSync = Date(timeIntervalSince1970: 1_000_000)
        let now = lastSync.addingTimeInterval(30 * 60)
        let desired = BackgroundPropagationSchedulePolicy.desiredEarliest(
            kind: .refresh,
            userInterval: 3_600,
            now: now,
            lastSyncTime: lastSync
        )

        // A now-anchored submit would be one hour out; the last-run anchor
        // keeps the target at lastSync + interval.
        XCTAssertEqual(desired, lastSync.addingTimeInterval(3_600))
        XCTAssertLessThan(desired, now.addingTimeInterval(3_600))
    }

    func testSchedulePolicyStaysNearTermWhenNoSyncEverCompleted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let desired = BackgroundPropagationSchedulePolicy.desiredEarliest(
            kind: .processing,
            userInterval: 3_600,
            now: now,
            lastSyncTime: nil
        )

        XCTAssertEqual(desired, now.addingTimeInterval(60))
    }

    /// Regression guard for the stale-timestamp cadence bug (Greptile P1,
    /// PR #206). When a due task re-arms using the PREVIOUS run's completion
    /// time, `desiredEarliest` returns a near-term target (the floor), NOT
    /// the user's interval. This is exactly why the re-arm must be deferred to
    /// after the anchor is advanced by `markSyncCompleted` - re-arming from
    /// `deliver` with this stale anchor would let the OS grant the next run
    /// almost immediately instead of after the configured cadence.
    func testSchedulePolicyStaysNearTermWhenRearmedFromStalePreviousAnchor() {
        // The lane's pending request targets now+interval; the OS grants it
        // on time, and the task is delivered. The completion timestamp is
        // still the PREVIOUS run's (one full interval in the past).
        let previousCompletion = Date(timeIntervalSince1970: 1_000_000)
        let now = previousCompletion.addingTimeInterval(3_600)
        let interval: TimeInterval = 3_600

        let desired = BackgroundPropagationSchedulePolicy.desiredEarliest(
            kind: .refresh,
            userInterval: interval,
            now: now,
            lastSyncTime: previousCompletion
        )

        // A correct (post-completion) re-arm would be one interval out...
        let correctTarget = now.addingTimeInterval(interval)
        // ...but the stale previous anchor collapses to the near-term floor.
        XCTAssertEqual(desired, now.addingTimeInterval(60))
        XCTAssertLessThan(
            desired.timeIntervalSince(correctTarget),
            -interval / 2
        )
    }

    func testBothLanesUseTheSameUserConfiguredInterval() {
        // Both task lanes must honor the user's chosen cadence (floored at
        // the 15-minute platform minimum). The processing lane is extra grant
        // opportunity, not a second, faster schedule.
        XCTAssertEqual(
            BackgroundPropagationSchedulePolicy.processingInterval(userInterval: 60),
            BackgroundPropagationSchedulePolicy.refreshInterval(userInterval: 60)
        )
        XCTAssertEqual(BackgroundPropagationSchedulePolicy.processingInterval(userInterval: 60), 15 * 60)
        XCTAssertEqual(
            BackgroundPropagationSchedulePolicy.processingInterval(userInterval: 30 * 60),
            BackgroundPropagationSchedulePolicy.refreshInterval(userInterval: 30 * 60)
        )
        XCTAssertEqual(BackgroundPropagationSchedulePolicy.processingInterval(userInterval: 30 * 60), 30 * 60)
        XCTAssertEqual(
            BackgroundPropagationSchedulePolicy.processingInterval(userInterval: 3_600),
            BackgroundPropagationSchedulePolicy.refreshInterval(userInterval: 3_600)
        )
    }

    func testShouldSkipSubmitKeepsEarlierOrOverduePendingRequests() {
        let desired = Date(timeIntervalSince1970: 1_000_000)

        // A nil earliestBeginDate can start any time; replacing it only moves it later.
        XCTAssertTrue(
            BackgroundPropagationSchedulePolicy.shouldSkipSubmit(
                existingEarliest: nil,
                desiredEarliest: desired
            )
        )
        // Overdue requests are what iOS is already waiting on.
        XCTAssertTrue(
            BackgroundPropagationSchedulePolicy.shouldSkipSubmit(
                existingEarliest: desired.addingTimeInterval(-60),
                desiredEarliest: desired
            )
        )
        // Within the 5s tolerance, the difference is insignificant.
        XCTAssertTrue(
            BackgroundPropagationSchedulePolicy.shouldSkipSubmit(
                existingEarliest: desired.addingTimeInterval(4),
                desiredEarliest: desired
            )
        )
        // A pending request that starts later must be replaced with the earlier one.
        XCTAssertFalse(
            BackgroundPropagationSchedulePolicy.shouldSkipSubmit(
                existingEarliest: desired.addingTimeInterval(60),
                desiredEarliest: desired
            )
        )
    }

    func testCoordinatorCompletesEachDeliveredTaskKindIndependently() async {
        let coordinator = BackgroundTaskCoordinator(suspensionController: DatabaseSuspensionController(
            isForeground: true, notificationCenter: NotificationCenter()
        ))
        let refreshTask = FakeBackgroundTaskHandle()
        let processingTask = FakeBackgroundTaskHandle()
        var handlerRuns = 0

        coordinator.receive(refreshTask)
        coordinator.receive(processingTask)
        XCTAssertTrue(refreshTask.completions.isEmpty)
        XCTAssertTrue(processingTask.completions.isEmpty)

        // Both deliveries must be tracked independently (one state each) and
        // each task must report exactly one completion. Fast, non-blocking
        // handler so the test cannot wedge on a gate that is opened before
        // the handler task has started waiting.
        coordinator.installHandler {
            handlerRuns += 1
            await Task.yield()
            return true
        }
        await refreshTask.waitForCompletion()
        await processingTask.waitForCompletion()

        XCTAssertEqual(handlerRuns, 2)
        XCTAssertEqual(refreshTask.completions, [true])
        XCTAssertEqual(processingTask.completions, [true])
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

    func testBuiltAppDeclaresBackgroundTaskRequirements() throws {
        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        let identifiers = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )

        XCTAssertTrue(modes.contains("fetch"))
        XCTAssertTrue(modes.contains("processing"))
        XCTAssertTrue(identifiers.contains(BackgroundPropagationTaskScheduler.refreshTaskIdentifier))
        XCTAssertTrue(identifiers.contains(BackgroundPropagationTaskScheduler.processingTaskIdentifier))
    }

    func testHostEventGateKeepsNormalDrainOutsideBackgroundTransaction() async {
        let gate = PythonHostEventProcessingGate()
        let events = EventRecorder()

        let acquired = await gate.beginExclusive()
        XCTAssertTrue(acquired)
        let normalDrain = Task {
            guard await gate.beginNormal() else { return }
            await events.append("normal")
            await gate.endNormal()
        }
        try? await Task.sleep(for: .milliseconds(20))
        let beforeRelease = await events.snapshot()
        XCTAssertEqual(beforeRelease, [])

        await gate.endExclusive()
        await normalDrain.value
        let afterRelease = await events.snapshot()
        XCTAssertEqual(afterRelease, ["normal"])
    }

    func testFailedPropagationNodeRestoreRollsBackBeforeLifecycleActivationAndRetry() async {
        var backendRunning = false
        var starts = 0
        var rollbacks = 0
        var lifecycleActivations = 0

        for _ in 0..<5 {
            do {
                try await InitializationLifecycleActivation.run(
                    readiness: {
                        if !backendRunning {
                            backendRunning = true
                            starts += 1
                        }
                        try await PropagationNodeRestoreReadiness.validate(
                            reapplied: false,
                            rollback: {
                                backendRunning = false
                                rollbacks += 1
                            }
                        )
                    },
                    activate: {
                        lifecycleActivations += 1
                    }
                )
                XCTFail("Failed propagation-node restoration must not report readiness")
            } catch {
                XCTAssertEqual(error as? AppServicesError, .propagationNodeRestoreFailed)
            }
            XCTAssertFalse(backendRunning)
            XCTAssertEqual(lifecycleActivations, 0)
        }

        try? await InitializationLifecycleActivation.run(
            readiness: {
                if !backendRunning {
                    backendRunning = true
                    starts += 1
                }
                try await PropagationNodeRestoreReadiness.validate(
                    reapplied: true,
                    rollback: {
                        backendRunning = false
                        rollbacks += 1
                    }
                )
            },
            activate: {
                lifecycleActivations += 1
            }
        )

        XCTAssertTrue(backendRunning)
        XCTAssertEqual(starts, 6)
        XCTAssertEqual(rollbacks, 5)
        XCTAssertEqual(lifecycleActivations, 1)
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

    func testWorkflowTransfersDurableDeltaNotificationsWhenSyncFails() async {
        var loaded = false
        var notified: [String] = []
        let workflow = BackgroundPropagationSyncWorkflow<String>(
            captureInsertionCursor: { 7 },
            sync: { false },
            messagesInsertedAfter: { _ in
                loaded = true
                return ["concurrent-live"]
            },
            notify: { notified.append($0) }
        )

        let succeeded = await workflow.run()

        XCTAssertFalse(succeeded)
        XCTAssertTrue(loaded)
        XCTAssertEqual(notified, ["concurrent-live"])
    }

    func testTaskReceivedBeforeHandlerRunsAfterHandlerInstallation() async {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let coordinator = BackgroundTaskCoordinator(suspensionController: controller)
        let task = FakeBackgroundTaskHandle()

        coordinator.receive(task)
        XCTAssertTrue(task.completions.isEmpty)
        XCTAssertEqual(notifications.accessStates, [false, true])

        coordinator.installHandler {
            XCTAssertEqual(notifications.accessStates, [false, true])
            return true
        }
        await task.waitForCompletion()

        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(notifications.accessStates, [false, true, false])
    }

    func testExpirationRevokesGrantBeforeCleanupThenCompletesOnceWithoutLateResume() async {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let coordinator = BackgroundTaskCoordinator(suspensionController: controller)
        let task = FakeBackgroundTaskHandle()
        let gate = AsyncGate()
        let started = expectation(description: "handler started")

        coordinator.installHandler {
            started.fulfill()
            await gate.wait()
            return true
        }
        coordinator.receive(task)
        await fulfillment(of: [started], timeout: 2)
        let expiration = task.expirationHandler

        task.expire()
        expiration?()
        XCTAssertEqual(notifications.accessStates, [false, true, false])
        XCTAssertTrue(task.completions.isEmpty, "Cleanup still owns exactly-once completion")

        gate.open()
        await task.waitForCompletion()
        expiration?()
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(notifications.accessStates, [false, true, false])
    }

    func testRetainedTaskExpirationReleasesGrantAndNeverStartsAfterHandlerInstallation() async {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let coordinator = BackgroundTaskCoordinator(suspensionController: controller)
        let task = FakeBackgroundTaskHandle()
        task.onCompletion = { _ in
            XCTAssertEqual(notifications.accessStates, [false, true, false])
        }

        coordinator.receive(task)
        let expiration = task.expirationHandler
        task.expire()
        expiration?()
        coordinator.installHandler {
            XCTFail("An expired retained delivery must not run or reacquire access")
            return true
        }
        coordinator.receive(task)
        await Task.yield()

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(notifications.accessStates, [false, true, false])
    }

    func testTaskExpiredBeforeMainActorHandoffNeverResumesDatabase() {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let coordinator = BackgroundTaskCoordinator(suspensionController: controller)
        let task = FakeBackgroundTaskHandle()
        task.expire()

        coordinator.receive(task)
        coordinator.installHandler {
            XCTFail("Expired launch delivery must not initialize the workflow")
            return true
        }

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(notifications.accessStates, [false])
    }

    func testExpirationBeforeQueuedHandlerStartsNeverRunsWorkflow() async {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let coordinator = BackgroundTaskCoordinator(suspensionController: controller)
        let task = FakeBackgroundTaskHandle()
        coordinator.installHandler {
            XCTFail("Expiration must win over a queued handler")
            return true
        }

        coordinator.receive(task)
        task.expire()
        await task.waitForCompletion()

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(notifications.accessStates, [false, true, false])
    }

    func testOverlappingTaskExpirationKeepsOtherGrantAndForegroundUsable() async {
        let notifications = DatabaseSuspensionNotifications()
        let controller = DatabaseSuspensionController(
            isForeground: false, notificationCenter: notifications.center
        )
        let coordinator = BackgroundTaskCoordinator(suspensionController: controller)
        let first = FakeBackgroundTaskHandle()
        let second = FakeBackgroundTaskHandle()
        let gate = AsyncGate()
        let started = expectation(description: "remaining handler started")

        coordinator.receive(first)
        coordinator.receive(second)
        first.expire()
        XCTAssertEqual(first.completions, [false])
        XCTAssertEqual(notifications.accessStates, [false, true])

        coordinator.installHandler {
            started.fulfill()
            await gate.wait()
            return true
        }
        await fulfillment(of: [started], timeout: 2)
        controller.setForeground(true)
        second.expire()
        XCTAssertEqual(notifications.accessStates, [false, true])

        gate.open()
        await second.waitForCompletion()
        XCTAssertEqual(second.completions, [false])
        XCTAssertEqual(notifications.accessStates, [false, true])
        controller.setForeground(false)
        XCTAssertEqual(notifications.accessStates, [false, true, false])
    }

    func testTaskSuccessAndFailureReleaseGrantBeforeExactlyOnceCompletion() async {
        for success in [true, false] {
            let notifications = DatabaseSuspensionNotifications()
            let controller = DatabaseSuspensionController(
                isForeground: false, notificationCenter: notifications.center
            )
            let coordinator = BackgroundTaskCoordinator(suspensionController: controller)
            let task = FakeBackgroundTaskHandle()
            task.onCompletion = { _ in
                XCTAssertEqual(notifications.accessStates, [false, true, false])
            }
            coordinator.installHandler { success }
            coordinator.receive(task)
            let lateExpiration = task.expirationHandler
            await task.waitForCompletion()
            lateExpiration?()
            coordinator.receive(task)

            XCTAssertEqual(task.completions, [success])
            XCTAssertEqual(notifications.accessStates, [false, true, false])
        }
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

private actor EventRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private final class FakeBackgroundTaskHandle: BackgroundTaskHandle {
    var expirationHandler: (() -> Void)?
    var onCompletion: ((Bool) -> Void)?
    private(set) var isExpired = false
    private(set) var completions: [Bool] = []
    private var continuation: CheckedContinuation<Void, Never>?
    var isCompleted: Bool { !completions.isEmpty }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
        onCompletion?(success)
        continuation?.resume()
        continuation = nil
    }

    func waitForCompletion() async {
        if !completions.isEmpty { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func expire() {
        isExpired = true
        expirationHandler?()
    }
}

@MainActor
private final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class DatabaseSuspensionNotifications: @unchecked Sendable {
    let center = NotificationCenter()
    private let lock = NSLock()
    private var states: [Bool] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        observers = [
            center.addObserver(forName: Database.resumeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.record(true)
            },
            center.addObserver(forName: Database.suspendNotification, object: nil, queue: nil) { [weak self] _ in
                self?.record(false)
            }
        ]
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    var accessStates: [Bool] {
        lock.withLock { states }
    }

    private func record(_ allowed: Bool) {
        lock.withLock { states.append(allowed) }
    }
}

@MainActor
private final class ControlledPropagationSync {
    var started: XCTestExpectation?
    private var continuation: CheckedContinuation<PropagationSyncResult, Never>?
    private(set) var cancellations = 0

    func run(timeout: TimeInterval) async -> PropagationSyncResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.fulfill()
        }
    }

    func cancel() {
        cancellations += 1
        finish(PropagationSyncResult(ok: false, state: .cancelled, receivedMessages: 0, reason: "cancelled"))
    }

    func complete() {
        finish(PropagationSyncResult(ok: true, state: .complete, receivedMessages: 3, reason: "ok"))
    }

    private func finish(_ result: PropagationSyncResult) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
