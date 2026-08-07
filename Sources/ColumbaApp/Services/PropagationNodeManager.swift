//
//  PropagationNodeManager.swift
//  ColumbaApp
//
//  App-level service for propagation node discovery, selection, and sync scheduling.
//  Observes PathTable for propagation node announces and manages relay selection.
//

import Foundation
import RNSAPI
import Observation
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
        displayName ?? "Peer \(hash.prefix(4).map { String(format: "%02X", $0) }.joined())"
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

    /// Destination hash of the currently selected relay node (lxmf.propagation aspect).
    public var selectedNodeHash: Data?

    /// Delivery destination hash for the selected relay (lxmf.delivery aspect).
    /// Used to match the relay against saved contacts which use the delivery hash.
    public var selectedNodeDeliveryHash: Data?

    /// Display name of the selected relay node.
    public var selectedNodeName: String?

    /// Proof-of-work stamp cost the selected relay requires for uploads. Tracked
    /// here (not just computed locally) so the Model B App-Group seam can carry the
    /// correct cost to the NE; persisted across cold starts via SettingsRepository.
    public private(set) var selectedNodeStampCost: Int = 0

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
    private let logger = Logger(subsystem: "network.columba.Columba", category: "PropagationNodeManager")

    /// Task for listening to path table updates.
    private var listenTask: Task<Void, Never>?

    /// Task for periodic sync.
    private var periodicSyncTask: Task<Void, Never>?

    /// Test seam proving that iOS does not run a second timer beside
    /// BGAppRefreshTask. Other platforms still use the in-process timer.
    var hasInProcessPeriodicSyncTaskForTesting: Bool {
        periodicSyncTask != nil
    }

    /// Main-actor single-flight guard shared by user, periodic, foreground, and
    /// BGAppRefreshTask synchronization requests.
    private var syncInFlight = false
    private var activeSyncOperationID: UUID?

    /// Observer token for the NE's propagation sync-state channel (Model B). The NE
    /// owns the router/sync, so live progress arrives as App-Group snapshots bridged
    /// to `propagationSyncStateChangedInApp`; we mirror them into `syncState`.
    #if COLUMBA_RUNTIME_MODEL_B
    private var syncStateObserverToken: NSObjectProtocol?
    #endif

    // MARK: - Initialization

    public init(appServices: AppServices) {
        self.appServices = appServices
    }

    // MARK: - Node Discovery

    /// Start listening for propagation node announces on the path table.
    public func startListening() {
        #if COLUMBA_RUNTIME_MODEL_B
        // Model B: mirror the NE's sync-state snapshots into `syncState` so the in-app
        // sync sheet reflects live progress (the NE owns the router; the app can't read
        // its transfer state directly).
        if syncStateObserverToken == nil {
            syncStateObserverToken = NotificationCenter.default.addObserver(
                forName: NotificationObserver.propagationSyncStateChangedInApp,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applySyncStateSnapshot() }
            }
        }
        #endif

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
        #if COLUMBA_RUNTIME_MODEL_B
        if let token = syncStateObserverToken {
            NotificationCenter.default.removeObserver(token)
            syncStateObserverToken = nil
        }
        #endif
    }

    #if COLUMBA_RUNTIME_MODEL_B
    /// Read the NE's latest sync-state snapshot (Model B) and mirror it into
    /// `syncState`, which the in-app sync sheet observes.
    private func applySyncStateSnapshot() {
        guard let snap = PropagationSyncStateSnapshot.loadFromAppGroup() else { return }
        syncState.state = Self.mapSnapshotPhase(snap.phase)
        syncState.receivedMessages = snap.received
        syncState.progress = snap.progress
        syncState.errorDescription = snap.errorDescription
        if snap.phase == .complete {
            syncState.lastSync = Date()
            lastSyncTime = syncState.lastSync
        }
    }

    /// Map the NE snapshot's coarse phase to the app's Compat sync state.
    private static func mapSnapshotPhase(_ phase: PropagationSyncStateSnapshot.Phase) -> PropagationTransferState.State {
        switch phase {
        case .idle: return .idle
        case .linking: return .linking
        case .linked: return .linked
        case .requesting, .receiving: return .transferring
        case .complete: return .complete
        case .failed: return .transferFailed
        }
    }
    #endif

    /// Process a path entry to check if it's a propagation node.
    private func processPathEntry(_ entry: PathEntry) async {
        guard entry.destinationAspect == .lxmfPropagation else { return }
        guard let appData = entry.appData else { return }
        guard let info = PropagationNodeInfo.parse(from: appData) else { return }
        guard info.enabled else { return }

        let hex = entry.destinationHash.map { String(format: "%02x", $0) }.joined()
        // Prefer display name from properly-parsed metadata dict (element[6])
        // over PathEntry's heuristic parsing which can fail on some formats
        let name = info.displayName ?? entry.displayName
        let node = PropagationNode(
            id: hex,
            hash: entry.destinationHash,
            displayName: name,
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

        // Auto-select if enabled.
        if autoSelectEnabled {
            await autoSelectBestNode()
        } else if let selectedHash = selectedNodeHash, node.hash == selectedHash {
            // Manually-selected node: re-wire it now that its announce has landed.
            // At loadPreferences the node isn't in knownNodes yet, so it's wired
            // with a placeholder stampCost=0; a PROPAGATED upload then carries no
            // stamp and a stamp-requiring PN rejects it — the message queues
            // forever (the launch `nodeFound=false` log was the tell). selectNode
            // re-resolves the node + pushes its real stamp cost to the router.
            await selectNode(hash: selectedHash)
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
        guard let entry = await appServices?.pathTable?.lookup(destinationHash: hash),
              entry.destinationAspect == .lxmfPropagation,
              let appData = entry.appData,
              let info = PropagationNodeInfo.parse(from: appData),
              info.enabled else {
            logger.warning("Rejected relay selection without exact enabled propagation aspect")
            return
        }
        selectedNodeHash = hash
        let node = knownNodes.first(where: { $0.hash == hash })
        selectedNodeName = node?.resolvedDisplayName ?? info.displayName ?? entry.displayName

        // Compute delivery hash for this identity so we can match against saved contacts.
        // Relay announces use lxmf.propagation aspect; contacts use lxmf.delivery aspect.
        if entry.publicKeys.count >= 64 {
            let identityHash = Hashing.truncatedHash(entry.publicKeys)
            let nameHash = Hashing.destinationNameHash(appName: "lxmf", aspects: ["delivery"])
            var combined = nameHash
            combined.append(identityHash)
            selectedNodeDeliveryHash = Hashing.truncatedHash(combined)
        } else {
            selectedNodeDeliveryHash = nil
        }

        // Wire to Python LXMRouter via the embedded backend. Compat
        // LXMRouter.setOutboundPropagationNode used to set a local var
        // only — Python's LXMF.LXMRouter.set_outbound_propagation_node
        // is what actually affects delivery.
        let stampCost = info.stampCost
        selectedNodeStampCost = stampCost
        #if COLUMBA_RUNTIME_PYTHON
        if let backend = appServices?.pythonBackend {
            do {
                _ = try await backend.setPropagationNode(destHashHex: hash.toHex(), stampCost: stampCost)
            } catch {
                logger.error("setPropagationNode failed: \(error.localizedDescription)")
            }
        }
        #endif
        // Keep the Compat-layer var in sync so any UI that still reads
        // router.outboundPropagationNode shows the right value.
        await appServices?.router?.setOutboundPropagationNode(hash)
        await appServices?.router?.setPropagationStampCost(stampCost)

        logger.info("Selected propagation node: \(self.selectedNodeName ?? "unknown")")
        await savePreferences()
    }

    /// Clear the selected relay node.
    public func clearSelection() async {
        selectedNodeHash = nil
        selectedNodeDeliveryHash = nil
        selectedNodeName = nil
        selectedNodeStampCost = 0

        #if COLUMBA_RUNTIME_PYTHON
        if let backend = appServices?.pythonBackend {
            do {
                _ = try await backend.setPropagationNode(destHashHex: "", stampCost: 0)
            } catch {
                logger.error("clear propagation node failed: \(error.localizedDescription)")
            }
        }
        #endif
        await appServices?.router?.setOutboundPropagationNode(nil)
        await appServices?.router?.setPropagationStampCost(0)

        logger.info("Cleared propagation node selection")
        await savePreferences()
    }

    // MARK: - Sync

    /// Trigger an immediate sync from the propagation node.
    ///
    /// If no propagation node is selected yet, auto-selects the best available node first.
    /// - Parameter userInitiated: `true` when the user explicitly triggered the sync (a
    ///   refresh button, pull-to-refresh, or a Sync Now action) — i.e. the cases that may
    ///   present the status sheet. Only these reset the displayed transfer state up front
    ///   (see below). Background, periodic, and on-foreground auto-syncs pass `false`.
    @discardableResult
    public func syncNow(
        userInitiated: Bool = false,
        timeout: TimeInterval = 60.0,
        operationID: UUID = UUID()
    ) async -> Bool {
        guard !syncInFlight else {
            logger.info("[SYNC] skipped overlapping propagation sync")
            DiagLog.log("[SYNC] rejected: propagation sync already in flight")
            return false
        }
        syncInFlight = true
        activeSyncOperationID = operationID
        defer {
            if activeSyncOperationID == operationID {
                activeSyncOperationID = nil
                syncInFlight = false
            }
        }

        // For user-initiated syncs only, reset transfer state up front so a freshly-opened
        // status sheet shows THIS sync's progress from a clean "connecting" slate, not the
        // previous run's stale "Download complete / N new messages". Background / periodic
        // / on-foreground syncs skip this so they never clobber a status sheet the user may
        // have left open on a prior result. Early-return guards below overwrite this with
        // the appropriate terminal state (e.g. .noPath).
        if userInitiated {
            syncState = PropagationTransferState(state: .linking)
        }

        // Model B: the LXMF router lives in the NE — the app can't sync in-process.
        // Ensure a PN is selected + its config is in the seam, then fire the sync-now
        // Darwin trigger. Real progress arrives back via the sync-state channel
        // (PropagationSyncStateSnapshot → syncState); the NE's overlap guard makes
        // repeated taps safe.
        #if COLUMBA_RUNTIME_MODEL_B
        do {
            if selectedNodeHash == nil && autoSelectEnabled,
               let best = knownNodes.first(where: { $0.isOnline }) ?? knownNodes.first {
                await selectNode(hash: best.hash)
            }
            guard selectedNodeHash != nil else {
                syncState.state = .noPath
                syncState.errorDescription = "No propagation node available"
                logger.warning("[SYNC] Model B: no propagation node, sync skipped")
                return false
            }
            publishPropagationSeam() // ensure the NE has the latest PN + stamp cost
            syncState.state = .linking
            syncState.errorDescription = nil
            PropagationSeamConfig.postSyncNowNotification()
            logger.info("[SYNC] Model B: posted sync-now to NE")
            return true
        }
        #elseif COLUMBA_RUNTIME_PYTHON

        guard let backend = appServices?.pythonBackend else {
            logger.error("[SYNC] Python backend not available")
            DiagLog.log("[SYNC] failed: Python backend unavailable")
            syncState.state = .linkFailed
            syncState.errorDescription = "Backend not available"
            return false
        }

        logger.info("[SYNC] syncNow called. knownNodes=\(self.knownNodes.count), selectedNodeHash=\(self.selectedNodeHash != nil ? "set" : "nil")")

        // Auto-select a propagation node if none is set and auto-select is enabled
        if selectedNodeHash == nil && autoSelectEnabled {
            if let best = knownNodes.first(where: { $0.isOnline }) {
                await selectNode(hash: best.hash)
                logger.info("[SYNC] Auto-selected online node: \(best.resolvedDisplayName) hops=\(best.hopCount)")
            } else if let best = knownNodes.first {
                await selectNode(hash: best.hash)
                logger.info("[SYNC] Auto-selected node (may be offline): \(best.resolvedDisplayName) hops=\(best.hopCount)")
            }
        }

        guard let nodeHash = selectedNodeHash else {
            syncState.state = .noPath
            syncState.errorDescription = "No propagation node available"
            logger.warning("[SYNC] No propagation nodes discovered, sync skipped")
            DiagLog.log("[SYNC] failed: no propagation node selected")
            return false
        }

        let nodeHex = nodeHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.info("[SYNC] Starting sync from propagation node \(nodeHex)")
        syncState.state = .linking
        syncState.errorDescription = nil

        do {
            let transaction = try await backend.propagationSyncAndDrain(timeout: timeout)
            await appServices?.processPythonEventsSynchronously(transaction.events)
            let result = transaction.result
            syncState.state = Self.mapPythonState(result.state)
            syncState.receivedMessages = result.receivedMessages
            syncState.errorDescription = result.ok ? nil : result.reason
            if result.ok {
                syncState.lastSync = Date()
                lastSyncTime = syncState.lastSync
            }
            logger.info("[SYNC] Sync \(result.ok ? "complete" : "failed"). state=\(result.state.rawValue) newMessages=\(result.receivedMessages)")
            DiagLog.log(
                "[SYNC] completed ok=\(result.ok) state=\(result.state.rawValue) "
                    + "received=\(result.receivedMessages) reason=\(result.reason)"
            )
            return result.ok
        } catch {
            syncState.state = .transferFailed
            syncState.errorDescription = error.localizedDescription
            logger.error("[SYNC] Sync failed: \(error.localizedDescription)")
            DiagLog.log("[SYNC] failed with error: \(error.localizedDescription)")
            return false
        }
        #endif
    }

    /// Interrupt an active shipping Python propagation sync. This is used by
    /// BGAppRefreshTask expiration so Python does not continue polling after the
    /// system revokes the refresh execution window.
    public func cancelActiveSync(operationID: UUID) async {
        guard activeSyncOperationID == operationID else {
            logger.info("[SYNC] ignored cancellation for inactive propagation sync")
            return
        }
        #if COLUMBA_RUNTIME_PYTHON
        await appServices?.pythonBackend?.cancelPropagationSync()
        #endif
    }

    /// Reapply the persisted relay after the embedded Python backend starts.
    /// Preference restoration happens before backend startup on a cold launch,
    /// so wiring only the Compat router leaves Python with no outbound node.
    @discardableResult
    public func reapplySelectedNodeToPythonBackend() async -> Bool {
        #if COLUMBA_RUNTIME_PYTHON
        guard let hash = selectedNodeHash,
              let backend = appServices?.pythonBackend else { return false }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        do {
            return try await backend.setPropagationNode(
                destHashHex: hex,
                stampCost: selectedNodeStampCost
            )
        } catch {
            logger.error("[SYNC] Failed to reapply persisted propagation node: \(error.localizedDescription)")
            return false
        }
        #else
        return false
        #endif
    }

    /// Translate Python LXMRouter PR_* state names to Compat
    /// PropagationTransferState cases. (Subset mapped; non-terminal
    /// intermediate states collapse to .transferring for UI purposes.)
    private static func mapPythonState(_ state: PropagationSyncResult.State) -> PropagationTransferState.State {
        switch state {
        case .complete: return .complete
        case .cancelled: return .transferFailed
        case .noPath: return .noPath
        case .transferFailed: return .transferFailed
        case .pathRequested, .linkEstablishing, .linkEstablished:
            return .linking
        case .requestSent, .receiving, .responseReceived:
            return .transferring
        case .idle, .noRouter, .notStarted, .noNode, .unknown:
            return .idle
        }
    }

    /// Start periodic sync on the configured interval.
    public func startPeriodicSync() {
        #if COLUMBA_RUNTIME_MODEL_B
        // Model B: the NE owns the sync cadence (it owns the router). Publish the
        // current interval/enabled to the seam; the NE's scheduler honors
        // `periodicSyncEnabled` and re-kicks on the config-changed notification.
        publishPropagationSeam()
        return
        #elseif COLUMBA_RUNTIME_PYTHON

        #if os(iOS)
        // BGAppRefreshTask is the only periodic scheduler on iOS. Keeping this
        // sleeping task as well causes both operations to resume on the same
        // system wake, and the shared single-flight guard rejects one of them.
        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        logger.info("[SYNC] in-process periodic timer disabled; BGAppRefreshTask owns iOS cadence")
        return
        #else
        guard periodicSyncEnabled else { return }

        periodicSyncTask?.cancel()
        periodicSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(syncInterval))
                guard !Task.isCancelled else { break }
                await syncNow()
            }
        }
        #endif
        #endif
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

        let savedHashHex = await settingsRepository.getManualRelayHash()
        let savedName = await settingsRepository.getManualRelayName()
        DiagLog.log("[PROP_MGR] loadPreferences: autoSelect=\(autoSelectEnabled), savedHash=\(savedHashHex ?? "nil"), savedName=\(savedName ?? "nil")")

        if let hashHex = savedHashHex, !hashHex.isEmpty {
            let hash = Data(hexString: hashHex)
            if let hash = hash {
                selectedNodeHash = hash
                let node = knownNodes.first(where: { $0.hash == hash })
                selectedNodeName = node?.resolvedDisplayName ?? savedName
                autoSelectEnabled = false

                // Restore delivery hash for contact matching
                if let deliveryHex = await settingsRepository.getManualRelayDeliveryHash(),
                   let deliveryHash = Data(hexString: deliveryHex) {
                    selectedNodeDeliveryHash = deliveryHash
                }

                DiagLog.log("[PROP_MGR] Restored relay: hash=\(hashHex.prefix(16)), name=\(selectedNodeName ?? "nil"), nodeFound=\(node != nil)")

                // Wire to router (awaited directly, not fire-and-forget). The node
                // usually isn't in knownNodes yet at load (announce hasn't landed),
                // so fall back to the persisted stamp cost for a correct cold start;
                // processPathEntry re-resolves the live cost when the announce arrives.
                let persistedCost = await settingsRepository.getManualRelayStampCost() ?? 0
                let stampCost = node?.info.stampCost ?? persistedCost
                selectedNodeStampCost = stampCost
                await appServices?.router?.setOutboundPropagationNode(hash)
                await appServices?.router?.setPropagationStampCost(stampCost)
            }
        }

        if let timestamp = await settingsRepository.getLastSyncTimestamp() {
            lastSyncTime = Date(timeIntervalSince1970: timestamp)
        }

        _ = defaultMethod // Used by SettingsViewModel

        // Model B: hand the restored PN + sync settings to the NE's router.
        #if COLUMBA_RUNTIME_MODEL_B
        publishPropagationSeam()
        #endif
    }

    /// Save preferences to SettingsRepository.
    public func savePreferences() async {
        await settingsRepository.setAutoSelectRelay(autoSelectEnabled)
        await settingsRepository.setPeriodicSyncEnabled(periodicSyncEnabled)
        await settingsRepository.setSyncInterval(syncInterval)

        if let hash = selectedNodeHash {
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            await settingsRepository.setManualRelayHash(hex)
            await settingsRepository.setManualRelayName(selectedNodeName)
            await settingsRepository.setManualRelayStampCost(selectedNodeStampCost)
            if let deliveryHash = selectedNodeDeliveryHash {
                let deliveryHex = deliveryHash.map { String(format: "%02x", $0) }.joined()
                await settingsRepository.setManualRelayDeliveryHash(deliveryHex)
            } else {
                await settingsRepository.setManualRelayDeliveryHash(nil)
            }
        } else {
            await settingsRepository.setManualRelayHash(nil)
            await settingsRepository.setManualRelayName(nil)
            await settingsRepository.setManualRelayDeliveryHash(nil)
            await settingsRepository.setManualRelayStampCost(nil)
        }

        if let time = lastSyncTime {
            await settingsRepository.setLastSyncTimestamp(time.timeIntervalSince1970)
        }

        // Model B: republish the seam so PN selection / sync-setting edits reach the
        // NE's router. The Python build owns the router and has no seam declarations.
        #if COLUMBA_RUNTIME_MODEL_B
        publishPropagationSeam()
        #endif
    }

    #if COLUMBA_RUNTIME_MODEL_B
    /// Model B: cross the App-Group seam to the NE's in-NE `LXMRouter`. The NE wires
    /// the PN + sync settings onto its router and runs the periodic sync there (the
    /// app can't call it directly). The Python build owns the router in-process and
    /// does not compile this helper.
    private func publishPropagationSeam() {
        if let hash = selectedNodeHash {
            PropagationSeamConfig(
                propagationNodeHash: hash,
                stampCost: selectedNodeStampCost,
                syncInterval: syncInterval,
                periodicSyncEnabled: periodicSyncEnabled
            ).saveToAppGroup()
        } else {
            PropagationSeamConfig.clearFromAppGroup()
        }
    }
    #endif
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
