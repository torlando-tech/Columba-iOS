//
//  BackgroundPropagationSync.swift
//  ColumbaApp
//
//  Owns iOS BackgroundTasks scheduling and the cold-launch handoff for
//  propagation-node synchronization in the shipping embedded-Python app.
//
//  Two system task kinds trigger the SAME sync workflow:
//  - BGAppRefreshTask (fetch mode): short refresh opportunities, typically
//    during the day while the phone is in use.
//  - BGProcessingTask (processing mode): longer wakes, typically overnight
//    while the device is charging.
//  Registering both maximizes the grant opportunities iOS gives us. Scheduling
//  is anchored to the last completed sync (not to the submit instant) so
//  repeated re-arming never pushes a pending request further out, and an
//  existing pending request is preserved when it can start no later than the
//  newly computed one.

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

/// The two system-scheduled task kinds that both trigger the same
/// propagation sync workflow.
enum BackgroundPropagationTaskKind: String, CaseIterable, Sendable {
    case refresh
    case processing

    var taskIdentifier: String {
        switch self {
        case .refresh:
            return "network.columba.Columba.sync"
        case .processing:
            return "network.columba.Columba.sync-processing"
        }
    }
}

enum BackgroundPropagationSchedulePolicy {
    static let minimumInterval: TimeInterval = 15 * 60
    static let defaultInterval: TimeInterval = 60 * 60
    /// Near-term floor for every submit: iOS treats earliestBeginDate as a
    /// lower bound, so this only prevents a past-due target from being
    /// requested as "run immediately".
    static let minimumDelay: TimeInterval = 60
    /// The processing lane is the longer-lived one. It never goes shorter
    /// than five minutes and never shorter than the refresh lane, so the two
    /// lanes do not collapse into the same cadence.
    static let processingMinimumInterval: TimeInterval = 5 * 60
    /// Differences smaller than this are ignored when deciding whether an
    /// existing pending request can be kept instead of replaced.
    static let replacementTolerance: TimeInterval = 5

    static func refreshInterval(userInterval: TimeInterval) -> TimeInterval {
        let requested = userInterval.isFinite && userInterval > 0
            ? userInterval
            : defaultInterval
        return max(minimumInterval, requested)
    }

    static func processingInterval(userInterval: TimeInterval) -> TimeInterval {
        max(processingMinimumInterval, refreshInterval(userInterval: userInterval))
    }

    /// Kept for the existing unit tests and settings diagnostics.
    static func nextDelay(
        periodicSyncEnabled: Bool,
        userInterval: TimeInterval
    ) -> TimeInterval? {
        guard periodicSyncEnabled else { return nil }
        return refreshInterval(userInterval: userInterval)
    }

    /// The earliest begin date to request for a lane. Anchored to the last
    /// completed sync so that re-submitting the same desired schedule does
    /// not drift the target later with every re-arm; floored at
    /// `now + minimumDelay` so a never-run (or failed) lane stays near-term.
    static func desiredEarliest(
        kind: BackgroundPropagationTaskKind,
        userInterval: TimeInterval,
        now: Date,
        lastSyncTime: Date?
    ) -> Date {
        let interval: TimeInterval
        switch kind {
        case .refresh:
            interval = refreshInterval(userInterval: userInterval)
        case .processing:
            interval = processingInterval(userInterval: userInterval)
        }
        let floor = now.addingTimeInterval(minimumDelay)
        guard let lastSyncTime else { return floor }
        return max(lastSyncTime.addingTimeInterval(interval), floor)
    }

    /// Decide whether an existing pending request can be kept instead of
    /// replaced. A nil earliestBeginDate means the request can start any
    /// time, so replacing it would only move it later. An overdue request
    /// (earliest already in the past) is likewise kept: iOS runs it when it
    /// chooses, and resubmitting pushes the target out.
    static func shouldSkipSubmit(
        existingEarliest: Date?,
        desiredEarliest: Date
    ) -> Bool {
        guard let existingEarliest else { return true }
        return existingEarliest <= desiredEarliest.addingTimeInterval(replacementTolerance)
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

/// Type-erased system background task so the coordinator can own both a
/// BGAppRefreshTask and a BGProcessingTask without duplicating the
/// exactly-once completion logic.
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    var isCompleted: Bool { get }
    func setTaskCompleted(success: Bool)
}

private final class LaunchOwnedBackgroundTask: BackgroundTaskHandle, @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var storedExpirationHandler: (() -> Void)?
    private var completed = false

    init(task: BGTask) {
        self.task = task
        task.expirationHandler = { [weak self] in self?.expire() }
    }

    var expirationHandler: (() -> Void)? {
        get { lock.withLock { storedExpirationHandler } }
        set { lock.withLock { storedExpirationHandler = newValue } }
    }

    var isCompleted: Bool {
        lock.withLock { completed }
    }

    func setTaskCompleted(success: Bool) {
        let shouldComplete = lock.withLock {
            guard !completed else { return false }
            completed = true
            storedExpirationHandler = nil
            return true
        }
        if shouldComplete {
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
    }

    private func expire() {
        if let handler = expirationHandler {
            handler()
        } else {
            setTaskCompleted(success: false)
        }
    }
}

/// Retains a task delivered before SwiftUI has installed the service-backed
/// handler. This closes the cold-launch race without relying on a lossy
/// NotificationCenter post. Both task kinds are retained here: the system
/// delivers them directly to the process, and the process may still be
/// launching the scene stack (which is not guaranteed to happen for a
/// background launch).
@MainActor
final class BackgroundTaskCoordinator {
    typealias Handler = @MainActor @Sendable () async -> Bool

    private final class TaskState {
        let task: any BackgroundTaskHandle
        var operation: Task<Void, Never>?
        var completed = false

        init(task: any BackgroundTaskHandle) {
            self.task = task
        }
    }

    static let shared = BackgroundTaskCoordinator()

    private var handler: Handler?
    private var states: [ObjectIdentifier: TaskState] = [:]

    func installHandler(_ handler: @escaping Handler) {
        self.handler = handler
        DiagLog.log("[BG-SYNC] coordinator handler installed retained=\(states.count)")
        for state in states.values where state.operation == nil && !state.completed {
            start(state)
        }
    }

    func receive(_ task: any BackgroundTaskHandle) {
        guard !task.isCompleted else {
            DiagLog.log("[BG-SYNC] coordinator ignored task already completed during launch handoff")
            return
        }
        let identifier = ObjectIdentifier(task)
        guard states[identifier] == nil else { return }

        let state = TaskState(task: task)
        states[identifier] = state
        DiagLog.log("[BG-SYNC] coordinator received handlerReady=\(handler != nil)")
        task.expirationHandler = { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                DiagLog.log("[BG-SYNC] task expiration requested")
                if let operation = state.operation {
                    // Let the operation's structured completion path report failure
                    // only after its Reticulum/Python cancellation cleanup returns.
                    operation.cancel()
                } else {
                    self.complete(state, success: false)
                }
            }
        }
        guard !task.isCompleted else {
            states.removeValue(forKey: identifier)
            return
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
            guard !Task.isCancelled else { return false }
            let syncSucceeded = await sync()

            // A failed or expired propagation attempt can still drain and persist
            // concurrent live inbound events while ordinary notifications are
            // suppressed. Transfer notification ownership for every durable delta
            // before suppression is released, even though task success stays false.
            let messages = try await messagesInsertedAfter(cursor)
            for message in messages {
                await notify(message)
            }
            return syncSucceeded && !Task.isCancelled
        } catch {
            backgroundPropagationLogger.error(
                "Background propagation sync workflow failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

enum BackgroundPropagationTaskScheduler {
    static let refreshTaskIdentifier = BackgroundPropagationTaskKind.refresh.taskIdentifier
    static let processingTaskIdentifier = BackgroundPropagationTaskKind.processing.taskIdentifier

    @MainActor private static var schedulingReconciliationActive = false
    private static let lastSyncKey = "backgroundSyncLastCompletedTime"
    private static let osVersionKey = "backgroundSyncIOSVersion"
    /// iOS does not start background tasks until the first unlock after a
    /// reboot, and pending requests can survive reboots with a stale
    /// earliestBeginDate. Force a fresh near-term submit shortly after boot.
    private static let rebootRecoveryWindow: TimeInterval = 600

    /// Register both launch handlers. BGTaskScheduler requires every handler
    /// to be registered during every launch (including a cold background
    /// launch), so this runs before any other launch work.
    @MainActor
    static func register() {
        logRuntime(context: "registration-attempt")
        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundPropagationTaskKind.refresh.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                DiagLog.log("[BG-SYNC] delivered unexpected task type for refresh")
                task.setTaskCompleted(success: false)
                return
            }
            deliver(task: refreshTask, kind: .refresh)
        }
        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundPropagationTaskKind.processing.taskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                DiagLog.log("[BG-SYNC] delivered unexpected task type for processing")
                task.setTaskCompleted(success: false)
                return
            }
            deliver(task: processingTask, kind: .processing)
        }
        DiagLog.log("[BG-SYNC] registration refresh=\(refreshRegistered) processing=\(processingRegistered)")
        logPendingRequests(context: "after-registration")
    }

    private static func deliver(task: BGTask, kind: BackgroundPropagationTaskKind) {
        let launchOwnedTask = LaunchOwnedBackgroundTask(task: task)
        backgroundPropagationLogger.info("System background \(kind.rawValue) task launch handler entered")
        Task { @MainActor in
            DiagLog.log("[BG-SYNC] system task delivered kind=\(kind.rawValue)")
            logRuntime(context: "task-delivered")
            scheduleFromCurrentSettings()
            BackgroundTaskCoordinator.shared.receive(launchOwnedTask)
        }
    }

    /// Reconcile the pending request for BOTH task kinds from the persisted
    /// user settings. Called after every task delivery, on scene transitions,
    /// on settings changes, and after startup.
    @MainActor
    static func scheduleFromCurrentSettings(force: Bool = false) {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        let enabled = defaults.bool(forKey: "periodicSyncEnabled")
        let rawInterval = defaults.double(forKey: "syncIntervalSeconds")
        let userInterval = rawInterval > 0
            ? rawInterval
            : BackgroundPropagationSchedulePolicy.defaultInterval

        guard BackgroundPropagationSchedulePolicy.nextDelay(
            periodicSyncEnabled: enabled,
            userInterval: userInterval
        ) != nil else {
            for kind in BackgroundPropagationTaskKind.allCases {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: kind.taskIdentifier)
            }
            backgroundPropagationLogger.info("Background propagation sync disabled")
            DiagLog.log("[BG-SYNC] scheduling disabled; pending requests cancelled")
            logRuntime(context: "scheduling-disabled")
            logPendingRequests(context: "after-cancel-disabled")
            return
        }

        guard !schedulingReconciliationActive else {
            DiagLog.log("[BG-SYNC] scheduling reconciliation already active")
            return
        }
        schedulingReconciliationActive = true

        // Resolve every shared-mutable input BEFORE entering the @Sendable
        // scheduler callback: UserDefaults is not Sendable and must not be
        // captured there.
        let now = Date()
        let lastSyncTime = (defaults.object(forKey: lastSyncKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        let recoveryForced = refreshRecoveryState(defaults: defaults)
        let forced = force || recoveryForced
        let desiredByKind = Dictionary(uniqueKeysWithValues: BackgroundPropagationTaskKind.allCases.map { kind in
            (kind, BackgroundPropagationSchedulePolicy.desiredEarliest(
                kind: kind,
                userInterval: userInterval,
                now: now,
                lastSyncTime: lastSyncTime
            ))
        })

        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            Task { @MainActor in
                defer { schedulingReconciliationActive = false }
                for kind in BackgroundPropagationTaskKind.allCases {
                    let desired = desiredByKind[kind]!
                    let existing = requests.first { $0.identifier == kind.taskIdentifier }
                    if let existing,
                       !forced,
                       BackgroundPropagationSchedulePolicy.shouldSkipSubmit(
                            existingEarliest: existing.earliestBeginDate,
                            desiredEarliest: desired
                       ) {
                        let earliest = existing.earliestBeginDate.map {
                            ISO8601DateFormatter().string(from: $0)
                        } ?? "nil"
                        DiagLog.log("[BG-SYNC] \(kind.rawValue) preserving existing pending request earliest=\(earliest)")
                        continue
                    }
                    submit(kind: kind, desired: desired, now: now, forced: forced)
                }
            }
        }
    }

    /// Anchor the next schedule to this run. Called exactly once per system
    /// grant (the coordinator hands the handler a single completion). Failed
    /// runs do not move the anchor, so the next lane stays near-term.
    @MainActor
    static func markSyncCompleted(success: Bool) {
        guard success else { return }
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        defaults.set(Date().timeIntervalSince1970, forKey: lastSyncKey)
        DiagLog.log("[BG-SYNC] last completed sync anchored")
    }

    /// Reboots and OS upgrades are observable one-off events: pending
    /// requests can survive both with a stale earliestBeginDate, so force a
    /// fresh near-term submit for that one reconciliation.
    @MainActor
    private static func refreshRecoveryState(defaults: UserDefaults) -> Bool {
        var forced = false
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime < rebootRecoveryWindow {
            DiagLog.log("[BG-SYNC] device booted within \(Int(uptime))s; forcing fresh schedule (post-reboot)")
            forced = true
        }
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let stored = defaults.string(forKey: osVersionKey)
        if stored != version {
            DiagLog.log("[BG-SYNC] iOS version changed; forcing fresh schedule (post-OS-upgrade)")
            forced = true
        }
        if forced {
            defaults.set(version, forKey: osVersionKey)
        }
        return forced
    }

    @MainActor
    private static func submit(
        kind: BackgroundPropagationTaskKind,
        desired: Date,
        now: Date,
        forced: Bool
    ) {
        let delay = max(0, desired.timeIntervalSince(now))
        do {
            switch kind {
            case .refresh:
                let request = BGAppRefreshTaskRequest(identifier: kind.taskIdentifier)
                request.earliestBeginDate = desired
                try BGTaskScheduler.shared.submit(request)
            case .processing:
                let request = BGProcessingTaskRequest(identifier: kind.taskIdentifier)
                request.earliestBeginDate = desired
                // The device is usually charging during processing windows, but
                // we prefer an off-charger wake over forfeiting the run.
                request.requiresExternalPower = false
                // Propagation may ride a BLE link, which needs no network.
                request.requiresNetworkConnectivity = false
                try BGTaskScheduler.shared.submit(request)
            }
            backgroundPropagationLogger.info(
                "Scheduled background propagation sync no earlier than \(Int(delay), privacy: .public)s (forced=\(forced, privacy: .public))"
            )
            let earliest = ISO8601DateFormatter().string(from: desired)
            DiagLog.log("[BG-SYNC] \(kind.rawValue) scheduled earliest delay=\(Int(delay))s date=\(earliest) forced=\(forced)")
            logRuntime(context: "after-submit")
            logPendingRequests(context: "after-submit")
        } catch {
            backgroundPropagationLogger.error(
                "Failed to schedule background propagation sync: \(error.localizedDescription, privacy: .public)"
            )
            DiagLog.log("[BG-SYNC] \(kind.rawValue) scheduling failed: \(error.localizedDescription)")
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
