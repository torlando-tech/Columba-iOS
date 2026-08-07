//
//  BackgroundPropagationSync.swift
//  ColumbaApp
//
//  Owns iOS BackgroundTasks scheduling and the cold-launch handoff for
//  propagation-node synchronization in the shipping embedded-Python app.
//

#if os(iOS)
import BackgroundTasks
import Foundation
import RNSAPI
import os

private let backgroundPropagationLogger = Logger(
    subsystem: "network.columba.Columba",
    category: "BackgroundPropagationSync"
)

enum BackgroundPropagationSchedulePolicy {
    static let minimumInterval: TimeInterval = 15 * 60
    static let defaultInterval: TimeInterval = 60 * 60

    static func nextDelay(
        periodicSyncEnabled: Bool,
        userInterval: TimeInterval
    ) -> TimeInterval? {
        guard periodicSyncEnabled else { return nil }
        let requested = userInterval.isFinite && userInterval > 0
            ? userInterval
            : defaultInterval
        return max(minimumInterval, requested)
    }
}

@MainActor
protocol BackgroundRefreshTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: BackgroundRefreshTaskHandle {}

/// Retains a task delivered before SwiftUI has installed the service-backed
/// handler. This closes the cold-launch race without relying on a lossy
/// NotificationCenter post.
@MainActor
final class BackgroundRefreshTaskCoordinator {
    typealias Handler = @MainActor @Sendable () async -> Bool

    private final class TaskState {
        let task: any BackgroundRefreshTaskHandle
        var operation: Task<Void, Never>?
        var completed = false

        init(task: any BackgroundRefreshTaskHandle) {
            self.task = task
        }
    }

    static let shared = BackgroundRefreshTaskCoordinator()

    private var handler: Handler?
    private var states: [ObjectIdentifier: TaskState] = [:]

    func installHandler(_ handler: @escaping Handler) {
        self.handler = handler
        for state in states.values where state.operation == nil && !state.completed {
            start(state)
        }
    }

    func receive(_ task: any BackgroundRefreshTaskHandle) {
        let identifier = ObjectIdentifier(task)
        guard states[identifier] == nil else { return }

        let state = TaskState(task: task)
        states[identifier] = state
        task.expirationHandler = { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                state.operation?.cancel()
                self.complete(state, success: false)
            }
        }

        if handler != nil {
            start(state)
        }
    }

    private func start(_ state: TaskState) {
        guard let handler, state.operation == nil, !state.completed else { return }
        state.operation = Task { @MainActor [weak self, weak state] in
            guard let self, let state else { return }
            let success = await handler()
            self.complete(state, success: success && !Task.isCancelled)
        }
    }

    private func complete(_ state: TaskState, success: Bool) {
        guard !state.completed else { return }
        state.completed = true
        state.task.expirationHandler = nil
        state.task.setTaskCompleted(success: success)
        states.removeValue(forKey: ObjectIdentifier(state.task))
    }
}

/// Small closure-based workflow that can be tested without constructing the
/// embedded Python runtime or a system BGAppRefreshTask.
@MainActor
struct BackgroundPropagationSyncWorkflow<Message> {
    let captureInsertionCursor: @MainActor () async throws -> Int64
    let sync: @MainActor () async -> Bool
    let messagesInsertedAfter: @MainActor (Int64) async throws -> [Message]
    let notify: @MainActor (Message) async -> Void

    func run() async -> Bool {
        do {
            let cursor = try await captureInsertionCursor()
            guard !Task.isCancelled, await sync(), !Task.isCancelled else {
                return false
            }
            let messages = try await messagesInsertedAfter(cursor)
            guard !Task.isCancelled else { return false }
            for message in messages {
                guard !Task.isCancelled else { return false }
                await notify(message)
            }
            return true
        } catch {
            backgroundPropagationLogger.error(
                "Background propagation sync workflow failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

enum BackgroundPropagationRefreshScheduler {
    static let taskIdentifier = "network.columba.Columba.sync"

    static func register() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                DiagLog.log("[BG-SYNC] system task delivered")
                scheduleFromCurrentSettings()
                BackgroundRefreshTaskCoordinator.shared.receive(refreshTask)
            }
        }
        DiagLog.log("[BG-SYNC] registration success=\(registered)")
    }

    @MainActor
    static func scheduleFromCurrentSettings() {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        let enabled = defaults.bool(forKey: "periodicSyncEnabled")
        let rawInterval = defaults.double(forKey: "syncIntervalSeconds")
        let interval = rawInterval > 0
            ? rawInterval
            : BackgroundPropagationSchedulePolicy.defaultInterval

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        guard let delay = BackgroundPropagationSchedulePolicy.nextDelay(
            periodicSyncEnabled: enabled,
            userInterval: interval
        ) else {
            backgroundPropagationLogger.info("Background propagation sync disabled")
            DiagLog.log("[BG-SYNC] scheduling disabled; pending request cancelled")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundPropagationLogger.info(
                "Scheduled background propagation sync no earlier than \(Int(delay), privacy: .public)s"
            )
            DiagLog.log("[BG-SYNC] scheduled earliest delay=\(Int(delay))s")
        } catch {
            backgroundPropagationLogger.error(
                "Failed to schedule background propagation sync: \(error.localizedDescription, privacy: .public)"
            )
            DiagLog.log("[BG-SYNC] scheduling failed: \(error.localizedDescription)")
        }
    }
}
#endif
