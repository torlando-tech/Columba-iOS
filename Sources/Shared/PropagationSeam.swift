//
//  PropagationSeam.swift
//  Columba Shared
//
//  Persisted relay selection and retrieval preferences for either node host.
//  Foundation-only: shared by the application and Network Extension.
//

import Foundation

/// Written by the app's PropagationNodeManager and read by the shared Python
/// node's retrieval scheduler. Changes apply without restarting the node.
public struct PropagationSeamConfig: Codable, Equatable, Sendable {
    /// The selected propagation node's destination hash (lxmf.propagation aspect), or
    /// nil when none is selected (clear the router's PN).
    public var propagationNodeHash: Data?
    /// Proof-of-work cost the PN requires for uploads (from its announce app_data).
    public var stampCost: Int
    /// Desired periodic-sync interval, in seconds. Use `effectiveSyncInterval` for the
    /// scheduler — a raw 0 / near-0 value (default/corrupted App-Group entry) would
    /// otherwise busy-loop the NE sync task.
    public var syncInterval: TimeInterval
    /// Whether the owning node should retrieve periodically.
    public var periodicSyncEnabled: Bool

    /// Hard floor for the periodic-sync cadence. The NE's `startPropagationSyncScheduler`
    /// sleeps `syncInterval` between syncs; a zero/near-zero value — reachable via a
    /// corrupted or unset App-Group entry (Codable decoding bypasses `init`, so an
    /// init-time clamp would not catch it) — would spin the loop at the ~2s relay-recheck
    /// floor, generating continuous IPC + relay traffic. Manual "Sync Now" and
    /// reconnect-triggered syncs are unaffected.
    public static let minSyncInterval: TimeInterval = 30

    /// `syncInterval` floored to `minSyncInterval`. Always use this for the periodic
    /// scheduler so no config path (including a direct Codable decode) can busy-loop it.
    public var effectiveSyncInterval: TimeInterval { Swift.max(Self.minSyncInterval, syncInterval) }

    public init(
        propagationNodeHash: Data?,
        stampCost: Int,
        syncInterval: TimeInterval,
        periodicSyncEnabled: Bool
    ) {
        self.propagationNodeHash = propagationNodeHash
        self.stampCost = stampCost
        self.syncInterval = syncInterval
        self.periodicSyncEnabled = periodicSyncEnabled
    }

    // MARK: App-Group persistence

    /// Read the persisted propagation config, or nil if none is selected.
    public static func loadFromAppGroup(_ group: String = appGroupIdentifier) -> PropagationSeamConfig? {
        guard let defaults = UserDefaults(suiteName: group),
              let data = defaults.data(forKey: SharedDefaultsConstants.propagationConfigKey),
              let config = try? JSONDecoder().decode(PropagationSeamConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// Persist this config to the App-Group (app side) + post the change notification.
    public func saveToAppGroup(_ group: String = appGroupIdentifier) {
        guard let defaults = UserDefaults(suiteName: group),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SharedDefaultsConstants.propagationConfigKey)
        Self.postChangedNotification()
    }

    /// Clear the persisted config (PN deselected) + post the change notification.
    public static func clearFromAppGroup(_ group: String = appGroupIdentifier) {
        UserDefaults(suiteName: group)?.removeObject(forKey: SharedDefaultsConstants.propagationConfigKey)
        postChangedNotification()
    }

    private static func postChangedNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(SharedDefaultsConstants.propagationConfigChangedNotificationName as CFString),
            nil, nil, true
        )
    }

    /// Ask the NE to run one immediate propagation sync (the "Sync Now" button — the app
    /// can't call the NE's router directly). Fire-and-forget Darwin notification.
    public static func postSyncNowNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(SharedDefaultsConstants.propagationSyncNowNotificationName as CFString),
            nil, nil, true
        )
    }
}

/// Compact, Foundation-only snapshot of an in-progress propagation sync, written by the
/// NE to the App-Group `propagationSyncStateKey` as the sync advances. The app reads it
/// (on the `propagationSyncStateChanged` Darwin notification) to drive the in-app sync
/// sheet, mapping it to its `PropagationTransferState`. Darwin carries no payload, so the
/// state rides this key.
public struct PropagationSyncStateSnapshot: Codable, Equatable, Sendable {
    /// Coarse phase the UI renders rows for. Raw values are stable across the JSON seam.
    public enum Phase: String, Codable, Sendable {
        case idle, linking, linked, requesting, receiving, complete, failed

        /// Whether a sync is currently in flight (drives showing/hiding the sync sheet).
        public var isActive: Bool {
            switch self {
            case .linking, .linked, .requesting, .receiving: return true
            case .idle, .complete, .failed: return false
            }
        }
    }

    public var phase: Phase
    public var progress: Double          // 0.0 ... 1.0
    public var received: Int
    public var total: Int
    public var errorDescription: String?

    public init(
        phase: Phase,
        progress: Double = 0,
        received: Int = 0,
        total: Int = 0,
        errorDescription: String? = nil
    ) {
        self.phase = phase
        self.progress = progress
        self.received = received
        self.total = total
        self.errorDescription = errorDescription
    }

    // MARK: App-Group persistence

    public static func loadFromAppGroup(_ group: String = appGroupIdentifier) -> PropagationSyncStateSnapshot? {
        guard let defaults = UserDefaults(suiteName: group),
              let data = defaults.data(forKey: SharedDefaultsConstants.propagationSyncStateKey),
              let snap = try? JSONDecoder().decode(PropagationSyncStateSnapshot.self, from: data) else {
            return nil
        }
        return snap
    }

    /// Persist this snapshot (NE side) + post the change notification.
    public func saveToAppGroup(_ group: String = appGroupIdentifier) {
        guard let defaults = UserDefaults(suiteName: group),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SharedDefaultsConstants.propagationSyncStateKey)
        Self.postChangedNotification()
    }

    public static func clearFromAppGroup(_ group: String = appGroupIdentifier) {
        UserDefaults(suiteName: group)?.removeObject(forKey: SharedDefaultsConstants.propagationSyncStateKey)
        postChangedNotification()
    }

    private static func postChangedNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(SharedDefaultsConstants.propagationSyncStateChangedNotificationName as CFString),
            nil, nil, true
        )
    }
}

/// Clock-driven policy shared by both node hosts; one attempt per interval.
/// Changing or disabling the selection invalidates the previous deadline.
struct NodePropagationSchedule {
    private var previous: PropagationSeamConfig?
    private var deadline: Date?

    mutating func shouldSync(config: PropagationSeamConfig?, now: Date) -> Bool {
        guard let config, config.periodicSyncEnabled,
              config.propagationNodeHash != nil else {
            previous = nil
            deadline = nil
            return false
        }
        if config != previous {
            previous = config
            deadline = now.addingTimeInterval(config.effectiveSyncInterval)
        }
        guard let deadline, now >= deadline else { return false }
        self.deadline = now.addingTimeInterval(config.effectiveSyncInterval)
        return true
    }
}
