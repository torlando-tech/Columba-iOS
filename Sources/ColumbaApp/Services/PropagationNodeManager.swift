//
//  PropagationNodeManager.swift
//  ColumbaApp
//
//  App-level service for propagation node discovery, selection, and sync scheduling.
//  Observes PathTable for propagation node announces and manages relay selection.
//

import Foundation
import Observation
import LXMFSwift
import ReticulumSwift
import os.log

/// Debug logging for propagation node manager.
private func appendPropMgrDebug(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/columba_propmgr_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Propagation Node Model

/// Display model for a discovered propagation node.
public struct PropagationNode: Identifiable, Sendable, Hashable {
    public let id: String
    public let hash: Data
    public let displayName: String?
    public let hopCount: Int
    public let info: PropagationNodeInfo
    public let discoveredAt: Date
    public let isOnline: Bool

    public var resolvedDisplayName: String {
        displayName ?? "Propagation Node"
    }

    public static func == (lhs: PropagationNode, rhs: PropagationNode) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - PropagationNodeManager

/// Manages propagation node discovery, selection, and sync scheduling.
///
/// Observes the path table for propagation node announces, supports auto-selection
/// of the best node (lowest hop count), and manages periodic sync scheduling.
@available(iOS 17.0, macOS 14.0, *)
@Observable
@MainActor
public final class PropagationNodeManager {

    // MARK: - Observable Properties

    /// Known propagation nodes discovered from announces, sorted by hop count.
    public private(set) var knownNodes: [PropagationNode] = []

    /// Destination hash of the currently selected relay node.
    public var selectedNodeHash: Data?

    /// Display name of the selected relay node.
    public var selectedNodeName: String?

    /// Whether to automatically select the best relay based on hop count.
    public var autoSelectEnabled: Bool = true

    /// Whether periodic sync is enabled.
    public var periodicSyncEnabled: Bool = false

    /// Interval between periodic syncs.
    public var syncInterval: TimeInterval = 3600 // 1 hour default

    /// Current sync state from the router.
    public var syncState = PropagationTransferState()

    /// Timestamp of last successful sync.
    public var lastSyncTime: Date?

    /// Whether a sync is currently in progress.
    public var isSyncing: Bool {
        syncState.isSyncing
    }

    // MARK: - Dependencies

    private weak var appServices: AppServices?
    private let logger = Logger(subsystem: "com.columba.app", category: "PropagationNodeManager")

    /// Task for listening to path table updates.
    private var listenTask: Task<Void, Never>?

    /// Task for periodic sync.
    private var periodicSyncTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(appServices: AppServices) {
        self.appServices = appServices
    }

    // MARK: - Node Discovery

    /// Start listening for propagation node announces on the path table.
    public func startListening() {
        guard let pathTable = appServices?.pathTable else {
            appendPropMgrDebug("[PROP_MGR] startListening: pathTable is nil, cannot start")
            return
        }

        listenTask?.cancel()
        listenTask = Task {
            // Initial scan of existing path entries
            let entries = await pathTable.allEntries()
            appendPropMgrDebug("[PROP_MGR] Initial scan: \(entries.count) path entries")
            for entry in entries {
                let hex = entry.destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                let hasAppData = entry.appData != nil
                appendPropMgrDebug("[PROP_MGR] Checking entry \(hex), appData=\(hasAppData ? "\(entry.appData!.count)B" : "nil")")
                await processPathEntry(entry)
            }
            appendPropMgrDebug("[PROP_MGR] Initial scan done, knownNodes=\(knownNodes.count), selectedNodeHash=\(selectedNodeHash != nil)")

            // Listen for new path entries
            for await entry in pathTable.pathUpdates {
                guard !Task.isCancelled else { break }
                await processPathEntry(entry)
            }
        }
    }

    /// Stop listening for updates.
    public func stopListening() {
        listenTask?.cancel()
        listenTask = nil
    }

    /// Process a path entry to check if it's a propagation node.
    private func processPathEntry(_ entry: PathEntry) async {
        guard let appData = entry.appData else { return }
        guard let info = PropagationNodeInfo.parse(from: appData) else { return }
        guard info.enabled else { return }

        let hex = entry.destinationHash.map { String(format: "%02x", $0) }.joined()
        let node = PropagationNode(
            id: hex,
            hash: entry.destinationHash,
            displayName: entry.displayName,
            hopCount: Int(entry.hopCount),
            info: info,
            discoveredAt: entry.timestamp,
            isOnline: Date() < entry.expires
        )

        // Update or insert
        if let index = knownNodes.firstIndex(where: { $0.id == node.id }) {
            knownNodes[index] = node
        } else {
            knownNodes.append(node)
        }

        // Sort by hop count (lowest first)
        knownNodes.sort { $0.hopCount < $1.hopCount }

        logger.info("Discovered propagation node: \(node.resolvedDisplayName) (\(hex.prefix(16))) hops=\(node.hopCount)")

        // Auto-select if enabled
        if autoSelectEnabled {
            await autoSelectBestNode()
        }
    }

    // MARK: - Node Selection

    /// Auto-select the best propagation node (lowest hop count, must be online).
    public func autoSelectBestNode() async {
        let onlineNodes = knownNodes.filter { $0.isOnline }
        guard let best = onlineNodes.first else { return }

        // Only switch if new node has strictly fewer hops
        if let currentHash = selectedNodeHash,
           let currentNode = knownNodes.first(where: { $0.hash == currentHash }),
           currentNode.hopCount <= best.hopCount {
            return // Current node is already optimal
        }

        await selectNode(hash: best.hash)
    }

    /// Manually select a propagation node.
    ///
    /// Disables auto-select when called manually.
    public func selectNode(hash: Data) async {
        selectedNodeHash = hash
        let node = knownNodes.first(where: { $0.hash == hash })
        selectedNodeName = node?.resolvedDisplayName

        // Wire to router (awaited directly, not fire-and-forget)
        let hashHex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let stampCost = node?.info.stampCost ?? 0
        appendPropMgrDebug("[PROP_MGR] selectNode: wiring \(hashHex) to router (router=\(appServices?.router != nil), stampCost=\(stampCost))")
        await appServices?.router?.setOutboundPropagationNode(hash)
        await appServices?.router?.setPropagationStampCost(stampCost)
        appendPropMgrDebug("[PROP_MGR] selectNode: wired successfully")

        logger.info("Selected propagation node: \(self.selectedNodeName ?? "unknown")")
    }

    /// Clear the selected relay node.
    public func clearSelection() async {
        selectedNodeHash = nil
        selectedNodeName = nil

        await appServices?.router?.setOutboundPropagationNode(nil)
        await appServices?.router?.setPropagationStampCost(0)

        logger.info("Cleared propagation node selection")
    }

    // MARK: - Sync

    /// Trigger an immediate sync from the propagation node.
    public func syncNow() async {
        guard let router = appServices?.router else {
            syncState.state = .linkFailed
            syncState.errorDescription = "Router not available"
            return
        }

        do {
            try await router.syncFromPropagationNode()
            syncState = await router.syncState
            lastSyncTime = syncState.lastSync
        } catch {
            syncState.state = .transferFailed
            syncState.errorDescription = error.localizedDescription
            logger.error("Sync failed: \(error.localizedDescription)")
        }
    }

    /// Start periodic sync on the configured interval.
    public func startPeriodicSync() {
        guard periodicSyncEnabled else { return }

        periodicSyncTask?.cancel()
        periodicSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(syncInterval))
                guard !Task.isCancelled else { break }
                await syncNow()
            }
        }
    }

    /// Stop periodic sync.
    public func stopPeriodicSync() {
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
    }

    // MARK: - Persistence

    /// Load preferences from SettingsRepository.
    public func loadPreferences() async {
        appendPropMgrDebug("[PROP_MGR] loadPreferences called")
        let settings = SettingsRepository()
        let defaultMethod = await settings.getDefaultDeliveryMethod()
        autoSelectEnabled = await settings.getAutoSelectRelay()
        periodicSyncEnabled = await settings.getPeriodicSyncEnabled()
        syncInterval = await settings.getSyncInterval()

        if let hashHex = await settings.getManualRelayHash(), !hashHex.isEmpty {
            appendPropMgrDebug("[PROP_MGR] loadPreferences: found saved relay hash=\(hashHex.prefix(16))")
            let hash = Data(hexString: hashHex)
            if let hash = hash {
                selectedNodeHash = hash
                let node = knownNodes.first(where: { $0.hash == hash })
                selectedNodeName = node?.resolvedDisplayName
                autoSelectEnabled = false

                // Wire to router (awaited directly, not fire-and-forget)
                let stampCost = node?.info.stampCost ?? 0
                appendPropMgrDebug("[PROP_MGR] loadPreferences: wiring saved hash to router (stampCost=\(stampCost))")
                await appServices?.router?.setOutboundPropagationNode(hash)
                await appServices?.router?.setPropagationStampCost(stampCost)
                appendPropMgrDebug("[PROP_MGR] loadPreferences: wired successfully")
            }
        } else {
            appendPropMgrDebug("[PROP_MGR] loadPreferences: no saved manual relay hash")
        }

        if let timestamp = await settings.getLastSyncTimestamp() {
            lastSyncTime = Date(timeIntervalSince1970: timestamp)
        }

        _ = defaultMethod // Used by SettingsViewModel
    }

    /// Save preferences to SettingsRepository.
    public func savePreferences() async {
        let settings = SettingsRepository()
        await settings.setAutoSelectRelay(autoSelectEnabled)
        await settings.setPeriodicSyncEnabled(periodicSyncEnabled)
        await settings.setSyncInterval(syncInterval)

        if let hash = selectedNodeHash {
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            await settings.setManualRelayHash(hex)
        } else {
            await settings.setManualRelayHash(nil)
        }

        if let time = lastSyncTime {
            await settings.setLastSyncTimestamp(time.timeIntervalSince1970)
        }
    }
}

// MARK: - LXMRouter Helper

extension LXMRouter {
    /// Set the outbound propagation node.
    public func setOutboundPropagationNode(_ hash: Data?) {
        self.outboundPropagationNode = hash
    }

    /// Set the stamp cost for the selected propagation node.
    public func setPropagationStampCost(_ cost: Int) {
        self.propagationStampCost = cost
    }
}

// MARK: - Data Hex Init

extension Data {
    /// Initialize Data from a hex string.
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
