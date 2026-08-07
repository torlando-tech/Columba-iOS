//
//  BackgroundPropagationSyncTests.swift
//  ColumbaAppTests
//

import XCTest
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
