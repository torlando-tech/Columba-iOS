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
import UIKit
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

struct PendingBackgroundRefreshRequestDiagnostic: Equatable {
    let identifier: String
    let earliestBeginDate: Date?
}

enum BackgroundRefreshDiagnosticFormatter {
    static func pendingRequests(
        _ requests: [PendingBackgroundRefreshRequestDiagnostic]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let entries = requests
            .sorted { $0.identifier < $1.identifier }
            .map { request in
                let earliest = request.earliestBeginDate.map(formatter.string(from:)) ?? "nil"
                return "\(request.identifier) earliest=\(earliest)"
            }
        return "count=\(entries.count) [\(entries.joined(separator: ", "))]"
    }

    static func runtime(
        processID: Int32,
        backgroundRefreshStatus: String,
        lowPowerModeEnabled: Bool,
        thermalState: String,
        protectedDataAvailable: Bool,
        sceneStates: [String]
    ) -> String {
        let scenes = sceneStates.sorted().joined(separator: ",")
        return "pid=\(processID) refresh=\(backgroundRefreshStatus) "
            + "lowPower=\(lowPowerModeEnabled) thermal=\(thermalState) "
            + "protectedData=\(protectedDataAvailable) scenes=\(scenes.isEmpty ? "none" : scenes)"
    }
}

private extension UIBackgroundRefreshStatus {
    var diagnosticValue: String {
        switch self {
        case .available: "available"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
    }
}

private extension ProcessInfo.ThermalState {
    var diagnosticValue: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

private extension UIScene.ActivationState {
    var diagnosticValue: String {
        switch self {
        case .unattached: "unattached"
        case .foregroundActive: "foregroundActive"
        case .foregroundInactive: "foregroundInactive"
        case .background: "background"
        @unknown default: "unknown"
        }
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
        DiagLog.log("[BG-SYNC] coordinator handler installed retained=\(states.count)")
        for state in states.values where state.operation == nil && !state.completed {
            start(state)
        }
    }

    func receive(_ task: any BackgroundRefreshTaskHandle) {
        let identifier = ObjectIdentifier(task)
        guard states[identifier] == nil else { return }

        let state = TaskState(task: task)
        states[identifier] = state
        DiagLog.log("[BG-SYNC] coordinator received handlerReady=\(handler != nil)")
        task.expirationHandler = { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                DiagLog.log("[BG-SYNC] task expiration requested")
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
        DiagLog.log("[BG-SYNC] coordinator starting workflow")
        state.operation = Task { @MainActor [weak self, weak state] in
            guard let self, let state else { return }
            let success = await handler()
            self.complete(state, success: success && !Task.isCancelled)
        }
    }

    private func complete(_ state: TaskState, success: Bool) {
        guard !state.completed else { return }
        state.completed = true
        DiagLog.log("[BG-SYNC] coordinator completing success=\(success)")
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

    @MainActor
    static func register() {
        logRuntime(context: "registration-attempt")
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                DiagLog.log("[BG-SYNC] delivered unexpected task type")
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                DiagLog.log("[BG-SYNC] system task delivered")
                logRuntime(context: "task-delivered")
                scheduleFromCurrentSettings()
                BackgroundRefreshTaskCoordinator.shared.receive(refreshTask)
            }
        }
        DiagLog.log("[BG-SYNC] registration success=\(registered)")
        logPendingRequests(context: "after-registration")
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
            logRuntime(context: "scheduling-disabled")
            logPendingRequests(context: "after-cancel-disabled")
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        do {
            try BGTaskScheduler.shared.submit(request)
            backgroundPropagationLogger.info(
                "Scheduled background propagation sync no earlier than \(Int(delay), privacy: .public)s"
            )
            let earliest = request.earliestBeginDate.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "nil"
            DiagLog.log("[BG-SYNC] scheduled earliest delay=\(Int(delay))s date=\(earliest)")
            logRuntime(context: "after-submit")
            logPendingRequests(context: "after-submit")
        } catch {
            backgroundPropagationLogger.error(
                "Failed to schedule background propagation sync: \(error.localizedDescription, privacy: .public)"
            )
            DiagLog.log("[BG-SYNC] scheduling failed: \(error.localizedDescription)")
            logRuntime(context: "submit-failed")
            logPendingRequests(context: "after-submit-failure")
        }
    }

    @MainActor
    static func logRuntime(context: String) {
        let application = UIApplication.shared
        let processInfo = ProcessInfo.processInfo
        let summary = BackgroundRefreshDiagnosticFormatter.runtime(
            processID: processInfo.processIdentifier,
            backgroundRefreshStatus: application.backgroundRefreshStatus.diagnosticValue,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState.diagnosticValue,
            protectedDataAvailable: application.isProtectedDataAvailable,
            sceneStates: application.connectedScenes.map { $0.activationState.diagnosticValue }
        )
        DiagLog.log("[BG-SYNC] runtime context=\(context) \(summary)")
    }

    @MainActor
    static func logPendingRequests(context: String) {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let snapshots = requests.map {
                PendingBackgroundRefreshRequestDiagnostic(
                    identifier: $0.identifier,
                    earliestBeginDate: $0.earliestBeginDate
                )
            }
            let summary = BackgroundRefreshDiagnosticFormatter.pendingRequests(snapshots)
            DiagLog.log("[BG-SYNC] pending context=\(context) \(summary)")
        }
    }
}
#endif
