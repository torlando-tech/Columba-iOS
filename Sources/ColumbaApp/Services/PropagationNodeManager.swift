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
    private let settingsRepository = SettingsRepository()
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
            return
        }

        listenTask?.cancel()
        listenTask = Task {
            // Initial scan of existing path entries
            let entries = await pathTable.allEntries()
            for entry in entries {
                await processPathEntry(entry)
            }

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

        // Update or insert, maintaining sorted order by hop count
        if let index = knownNodes.firstIndex(where: { $0.id == node.id }) {
            knownNodes.remove(at: index)
        }
        // Binary search for sorted insert position
        let insertIndex = knownNodes.firstIndex(where: { $0.hopCount > node.hopCount })
            ?? knownNodes.endIndex
        knownNodes.insert(node, at: insertIndex)

        logger.info("Discovered propagation node: \(node.resolvedDisplayName) (\(hex.prefix(16))) hops=\(node.hopCount)")

        // Auto-select if enabled
        if autoSelectEnabled {
            await autoSelectBestNode()
        }

        // DEBUG: Auto-sync on first node discovery
        if selectedNodeHash != nil && !isSyncing {
            logger.info("[DEBUG] Auto-triggering sync on node discovery")
            await syncNow()
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
        let stampCost = node?.info.stampCost ?? 0
        await appServices?.router?.setOutboundPropagationNode(hash)
        await appServices?.router?.setPropagationStampCost(stampCost)

        logger.info("Selected propagation node: \(self.selectedNodeName ?? "unknown")")
        await savePreferences()
    }

    /// Clear the selected relay node.
    public func clearSelection() async {
        selectedNodeHash = nil
        selectedNodeName = nil

        await appServices?.router?.setOutboundPropagationNode(nil)
        await appServices?.router?.setPropagationStampCost(0)

        logger.info("Cleared propagation node selection")
        await savePreferences()
    }

    // MARK: - Sync

    /// Trigger an immediate sync from the propagation node.
    ///
    /// If no propagation node is selected yet, auto-selects the best available node first.
    public func syncNow() async {
        guard let router = appServices?.router else {
            logger.error("[SYNC] Router not available")
            syncState.state = .linkFailed
            syncState.errorDescription = "Router not available"
            return
        }

        logger.info("[SYNC] syncNow called. knownNodes=\(self.knownNodes.count), selectedNodeHash=\(self.selectedNodeHash != nil ? "set" : "nil")")

        // Auto-select a propagation node if none is set
        if selectedNodeHash == nil {
            // Try online nodes first, then any node as fallback
            if let best = knownNodes.first(where: { $0.isOnline }) {
                await selectNode(hash: best.hash)
                logger.info("[SYNC] Auto-selected online node: \(best.resolvedDisplayName) hops=\(best.hopCount)")
            } else if let best = knownNodes.first {
                // isOnline is a snapshot from discovery time; node may still be reachable
                await selectNode(hash: best.hash)
                logger.info("[SYNC] Auto-selected node (may be offline): \(best.resolvedDisplayName) hops=\(best.hopCount)")
            }
        }

        guard let nodeHash = selectedNodeHash else {
            syncState.state = .noPath
            syncState.errorDescription = "No propagation node available"
            logger.warning("[SYNC] No propagation nodes discovered, sync skipped")
            return
        }

        let nodeHex = nodeHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.info("[SYNC] Starting sync from propagation node \(nodeHex)")

        do {
            try await router.syncFromPropagationNode()
            syncState = await router.syncState
            lastSyncTime = syncState.lastSync
            logger.info("[SYNC] Sync complete. newMessages=\(self.syncState.receivedMessages)")
        } catch {
            syncState.state = .transferFailed
            syncState.errorDescription = error.localizedDescription
            logger.error("[SYNC] Sync failed: \(error.localizedDescription)")
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
        let defaultMethod = await settingsRepository.getDefaultDeliveryMethod()
        autoSelectEnabled = await settingsRepository.getAutoSelectRelay()
        periodicSyncEnabled = await settingsRepository.getPeriodicSyncEnabled()
        syncInterval = await settingsRepository.getSyncInterval()

        if let hashHex = await settingsRepository.getManualRelayHash(), !hashHex.isEmpty {
            let hash = Data(hexString: hashHex)
            if let hash = hash {
                selectedNodeHash = hash
                let node = knownNodes.first(where: { $0.hash == hash })
                selectedNodeName = node?.resolvedDisplayName
                autoSelectEnabled = false

                // Wire to router (awaited directly, not fire-and-forget)
                let stampCost = node?.info.stampCost ?? 0
                await appServices?.router?.setOutboundPropagationNode(hash)
                await appServices?.router?.setPropagationStampCost(stampCost)
            }
        }

        if let timestamp = await settingsRepository.getLastSyncTimestamp() {
            lastSyncTime = Date(timeIntervalSince1970: timestamp)
        }

        _ = defaultMethod // Used by SettingsViewModel
    }

    /// Save preferences to SettingsRepository.
    public func savePreferences() async {
        await settingsRepository.setAutoSelectRelay(autoSelectEnabled)
        await settingsRepository.setPeriodicSyncEnabled(periodicSyncEnabled)
        await settingsRepository.setSyncInterval(syncInterval)

        if let hash = selectedNodeHash {
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            await settingsRepository.setManualRelayHash(hex)
        } else {
            await settingsRepository.setManualRelayHash(nil)
        }

        if let time = lastSyncTime {
            await settingsRepository.setLastSyncTimestamp(time.timeIntervalSince1970)
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
