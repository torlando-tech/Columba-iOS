//
//  AppServices.swift
//  ColumbaApp
//
//  Central service layer providing LXMF stack for the SwiftUI app.
//  Initializes and coordinates Identity, Transport, Router, and Destination.
//
//  This class serves as the single source of truth for all Reticulum/LXMF
//  networking components, exposing key properties for UI binding.
//

import Foundation
import RNSAPI
import LXSTSwift
import SwiftBLEBridge
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif
import os.log

/// Simple file logger for diagnostics when idevicesyslog isn't available (WiFi-only device).
/// Writes to Documents/diag.log which can be extracted via Xcode or devicectl.
enum DiagLog {
    private static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("diag.log")
    }()

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        NSLog("%@", message) // Also to ASL for USB capture
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let fh = try? FileHandle(forWritingTo: fileURL) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    #if COLUMBA_RUNTIME_MODEL_B
    /// Copy the Network Extension's App-Group diagnostic log
    /// (`ExtensionDiagLog`'s `ext-diag.log`) into the app's Documents directory
    /// as `ext-diag.log` so it's retrievable alongside `diag.log` via
    /// `devicectl ... copy from --domain-type appDataContainer`. The NE is
    /// sandboxed and can only write to the shared App-Group container; the host
    /// surfaces it on launch. No-op when the App-Group container or source file
    /// is unavailable. NO-PII: the source carries envelope/metadata only — see
    /// `ExtensionDiagLog`'s contract.
    static func copyExtensionDiagToDocuments() {
        guard let source = ExtensionDiagLog.fileURL,
              FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dest = docs.appendingPathComponent("ext-diag.log")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    #if DEBUG
    /// Keep `Documents/ext-diag.log` LIVE (refresh ~every 2s) instead of a single
    /// launch-time snapshot, so on-device NE diagnostics — including the smoke
    /// harness — can tail the NE's log in real time. The NE (sandboxed) writes to
    /// the App-Group container; the app is the only process that can bridge it into
    /// Documents (the appGroupDataContainer isn't reliably reachable via devicectl).
    /// DEBUG-only, self-rescheduling; a cheap small-file copy.
    static func startExtDiagLiveCopy() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            copyExtensionDiagToDocuments()
            startExtDiagLiveCopy()
        }
    }
    #endif
    #endif
}

actor PythonHostEventProcessingGate {
    private var exclusiveActive = false
    private var normalActive = false

    func beginExclusive() async -> Bool {
        while exclusiveActive || normalActive {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard !Task.isCancelled else { return false }
        exclusiveActive = true
        return true
    }

    func endExclusive() {
        exclusiveActive = false
    }

    func beginNormal() async -> Bool {
        while exclusiveActive || normalActive {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard !Task.isCancelled else { return false }
        normalActive = true
        return true
    }

    func endNormal() {
        normalActive = false
    }
}

/// Low-overhead, privacy-safe runtime instrumentation for physical-device soak tests.
///
/// Samples cumulative process CPU every 15 seconds, observes thermal-state changes,
/// and aggregates announce and path-table persistence activity. Diagnostic output
/// contains counts and interface classes only: no endpoints, hashes, names, or content.
final class RuntimeActivityMonitor: @unchecked Sendable {
    static let shared = RuntimeActivityMonitor()

    struct Lease: Hashable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let identifier: UInt64
    }

    private enum AnnounceSource {
        case tcp
        case ble
        case auto
        case other
    }

    private struct Counters {
        var announceTCP = 0
        var announceBLE = 0
        var announceAuto = 0
        var announceOther = 0
        var pathWrites = 0
        var pathWriteMilliseconds = 0.0
        var pathWriteMaxMilliseconds = 0.0

        var announceTotal: Int {
            announceTCP + announceBLE + announceAuto + announceOther
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "network.columba.runtime-activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var thermalObserver: NSObjectProtocol?
    private var counters = Counters()
    private var lastSampleUptime = ProcessInfo.processInfo.systemUptime
    private var lastCPUSeconds = 0.0
    private var generationCounter: UInt64 = 0
    private var activeGeneration: UInt64?
    private var nextLeaseIdentifier: UInt64 = 0
    private var activeLeases: Set<Lease> = []

    init() {}

    var activeLeaseCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeLeases.count
    }

    var isRunningForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration != nil
    }

    func acquire() -> Lease {
        lock.lock()
        nextLeaseIdentifier &+= 1

        if let generation = activeGeneration {
            let lease = Lease(
                generation: generation,
                identifier: nextLeaseIdentifier
            )
            activeLeases.insert(lease)
            lock.unlock()
            return lease
        }

        precondition(timer == nil && activeLeases.isEmpty)
        generationCounter &+= 1
        let generation = generationCounter
        activeGeneration = generation
        let lease = Lease(
            generation: generation,
            identifier: nextLeaseIdentifier
        )
        activeLeases.insert(lease)
        counters = Counters()
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        lastCPUSeconds = Self.processCPUSeconds()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            self?.emitSample(reason: "periodic", generation: generation)
        }
        self.timer = timer
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.emitSample(reason: "thermal_change", generation: generation)
        }
        lock.unlock()

        timer.activate()
        emitSample(reason: "start", generation: generation)
        return lease
    }

    func release(_ lease: Lease) {
        lock.lock()
        guard activeGeneration == lease.generation,
              activeLeases.remove(lease) != nil else {
            lock.unlock()
            return
        }
        guard activeLeases.isEmpty else {
            lock.unlock()
            return
        }
        guard let timer else {
            activeGeneration = nil
            lock.unlock()
            return
        }

        let observer = thermalObserver
        let finalLine = makeSampleLineLocked(reason: "stop")
        activeGeneration = nil

        // The last release owns teardown while holding the monitor lock. New
        // acquisitions and accepted callbacks cannot cross the final sample.
        timer.setEventHandler {}
        timer.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        DiagLog.log(finalLine)
        self.timer = nil
        thermalObserver = nil
        lock.unlock()
    }

    func recordAnnounce(interfaceName: String, configuredType: InterfaceType?) {
        let source = Self.classify(
            interfaceName: interfaceName,
            configuredType: configuredType
        )
        lock.lock()
        guard activeGeneration != nil else {
            lock.unlock()
            return
        }
        switch source {
        case .tcp: counters.announceTCP += 1
        case .ble: counters.announceBLE += 1
        case .auto: counters.announceAuto += 1
        case .other: counters.announceOther += 1
        }
        lock.unlock()
    }

    func recordPathTableWrite(durationMilliseconds: Double) {
        lock.lock()
        guard activeGeneration != nil else {
            lock.unlock()
            return
        }
        counters.pathWrites += 1
        counters.pathWriteMilliseconds += durationMilliseconds
        counters.pathWriteMaxMilliseconds = max(
            counters.pathWriteMaxMilliseconds,
            durationMilliseconds
        )
        lock.unlock()
    }

    private static func classify(
        interfaceName: String,
        configuredType: InterfaceType?
    ) -> AnnounceSource {
        if let configuredType {
            switch configuredType {
            case .tcpClient, .tcpServer: return .tcp
            case .ble: return .ble
            case .autoInterface, .multipeer: return .auto
            case .rnode: return .other
            }
        }

        // Dynamically spawned Auto/BLE peer interfaces do not have a matching
        // InterfaceEntity, so retain a class-name fallback for those children.
        let normalized = interfaceName.lowercased()
        if normalized.contains("tcp") { return .tcp }
        if normalized.contains("bluetooth") || normalized.contains("ble") { return .ble }
        if normalized.contains("auto") || normalized.contains("multipeer") { return .auto }
        return .other
    }

    private func emitSample(reason: String, generation: UInt64) {
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        let line = makeSampleLineLocked(reason: reason)
        // Publication is part of the generation's critical section. Teardown
        // cannot capture its final sample until every accepted callback line
        // has reached the diagnostic stream.
        DiagLog.log(line)
        lock.unlock()
    }

    /// Build and reset one interval while the caller holds `lock`.
    private func makeSampleLineLocked(reason: String) -> String {
        let now = ProcessInfo.processInfo.systemUptime
        let cpuNow = Self.processCPUSeconds()
        let elapsed = max(0.001, now - lastSampleUptime)
        let cpuPercent = max(0, cpuNow - lastCPUSeconds) / elapsed * 100
        let snapshot = counters
        counters = Counters()
        lastSampleUptime = now
        lastCPUSeconds = cpuNow

        let announceRate = Double(snapshot.announceTotal) / elapsed * 60
        let pathAverage = snapshot.pathWrites == 0
            ? 0
            : snapshot.pathWriteMilliseconds / Double(snapshot.pathWrites)
        return "[PERF] reason=\(reason) thermal=\(Self.thermalStateName()) sample_seconds=\(String(format: "%.1f", elapsed)) cpu_pct=\(String(format: "%.1f", cpuPercent)) announce_total=\(snapshot.announceTotal) announce_per_min=\(String(format: "%.1f", announceRate)) announce_tcp=\(snapshot.announceTCP) announce_ble=\(snapshot.announceBLE) announce_auto=\(snapshot.announceAuto) announce_other=\(snapshot.announceOther) path_writes=\(snapshot.pathWrites) path_write_ms_avg=\(String(format: "%.3f", pathAverage)) path_write_ms_max=\(String(format: "%.3f", snapshot.pathWriteMaxMilliseconds))"
    }

    private static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func processCPUSeconds() -> Double {
        #if canImport(Darwin)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
        #else
        return 0
        #endif
    }
}

/// RAII fallback for callers that fail to invoke AppServices.shutdown().
/// Normal mutation is main-actor confined by AppServices; holder destruction
/// releases any remaining generation-bound lease without actor-isolated access.
private final class RuntimeActivityMonitorLeaseHolder {
    var lease: RuntimeActivityMonitor.Lease?

    deinit {
        if let lease {
            RuntimeActivityMonitor.shared.release(lease)
        }
    }
}

/// Central LXMF service layer for the SwiftUI application.
///
/// AppServices initializes and holds all components needed for LXMF messaging:
/// - **Identity**: Local Reticulum identity for signing/encryption
/// - **LXMRouter**: LXMF message router for sending/receiving
/// - **ReticulumTransport**: Transport layer with path routing
/// - **TCPInterface**: TCP connection to server
/// - **Destination**: LXMF delivery destination for receiving messages
///
/// Uses `@Observable` macro (iOS 17+/macOS 14+) for SwiftUI integration.
///
/// Example usage:
/// ```swift
/// let services = AppServices()
/// try await services.initialize(tcpServerAddress: "tcp://10.0.0.1:4242")
///
/// // Access the router for sending messages
/// var message = LXMessage(...)
/// try await services.router?.handleOutbound(&message)
///
/// // UI can observe connection state
/// if services.isConnected {
///     // Show connected indicator
/// }
/// ```
@available(macOS 14.0, iOS 17.0, *)
@Observable
@MainActor
public final class AppServices {

    /// Host:port pair identifying a TCP interface's destination. Used to
    /// detect whether a `connectTCPInterface` call would change the
    /// interface's configuration or just re-apply the same one.
    public struct TCPEndpoint: Equatable, Hashable, Sendable {
        public let host: String
        public let port: UInt16
    }

    // MARK: - Components

    /// Local Reticulum identity for signing and encryption.
    public private(set) var identity: Identity?

    /// LXMF message router for sending and receiving messages.
    public private(set) var router: LXMRouter?

    /// Transport layer for packet routing.
    public private(set) var transport: ReticulumTransport?

    /// Path table for route lookups.
    public private(set) var pathTable: PathTable?

    /// TCP interfaces keyed by entity ID. Multiple concurrent connections are supported.
    public private(set) var tcpInterfaces: [String: TCPInterface] = [:]

    /// Last-applied host:port per TCP entity. Used by `connectTCPInterface`
    /// to short-circuit when the caller is re-applying an already-running
    /// config (e.g. `InterfaceManagementViewModel.applyChanges` loops over
    /// every enabled TCP entity on every toggle, so an unchanged interface
    /// would otherwise be torn down and recreated alongside the genuinely-
    /// changed one — triggering the relay to redeliver its full announce
    /// table per reconnect).
    public private(set) var tcpEndpoints: [String: TCPEndpoint] = [:]

    /// Convenience accessor for the first TCP interface (backward compat).
    public var tcpInterface: TCPInterface? { tcpInterfaces.values.first }

    /// RNode BLE interface for LoRa radio communication.
    public var rnodeInterface: RNodeInterface?

    /// Watchdog that fails a stuck RNode connect so the badge can't sit on
    /// "Connecting…" forever (see `startRNodeInterface`). Cancelled the moment the
    /// link leaves `.connecting` or the interface is stopped.
    private var rnodeConnectWatchdog: Task<Void, Never>?

    /// GATED (A5 item 3, RISK 1): when true the RNode Settings badge is driven by the NE's
    /// authoritative `ne-rnode` status and the app-side BLE link no longer greens it —
    /// killing the ~10s premature "connected". OFF by default: if `neRNodeStatus()` does not
    /// report online on a real connect, the badge would never go green, so verify on a
    /// physical RNode before flipping. Read by `applyRNodeLinkState` and the VM status loop.
    public static let rnodeBadgeFromNE = false

    /// Auto discovery interface for LAN peer discovery.
    public private(set) var autoInterface: AutoInterface?

    /// BLE interface for Bluetooth peer-to-peer networking.
    public private(set) var bleInterface: BLEInterface?

    #if canImport(MultipeerConnectivity)
    /// Multipeer Connectivity interface for peer-to-peer WiFi.
    public private(set) var mpcInterface: MPCInterface?
    #endif

    /// LXMF delivery destination for receiving messages.
    public private(set) var deliveryDestination: Destination?

    /// RNSAPI Compat LXMF database — still used by `IncomingMessageHandler`
    /// for sender-name lookups and by `CallManager`. NOT the canonical message
    /// store any more (that's the GRDB store behind `messageRepository`); kept
    /// because those collaborators take an `RNSAPI.LXMFDatabase`.
    public private(set) var database: LXMFDatabase?

    /// Filesystem path of the GRDB-backed canonical LXMF store
    /// (`<configDir>/lxmf-swift.db`) the Swift / NE backend writes. Set during
    /// `initialize(...)`. External call sites (ColumbaApp / MapView) read this
    /// and pass it to `MessageRepository(grdbPath:)` so they don't have to
    /// import LXMFSwift or re-derive the path.
    public private(set) var grdbDatabasePath: String?

    /// The repository over the GRDB canonical store, built once during
    /// `initialize(...)`. Held so the Python inbound-persist path
    /// (`persistInboundFromPython`) and delivery-state updates route their
    /// writes through the SAME store the UI reads, instead of constructing a
    /// throwaway repo or touching a separate store.
    public private(set) var messageRepository: MessageRepository?

    /// Propagation node manager for relay discovery and sync.
    public private(set) var propagationManager: PropagationNodeManager?

    /// Shared settings access for startup-time runtime configuration.
    private let settingsRepository = SettingsRepository()

    /// Auto announce manager for periodic network announces.
    public private(set) var autoAnnounceManager: AutoAnnounceManager?

    #if os(iOS)
    /// Location sharing manager for telemetry exchange with peers.
    public var locationSharingManager: LocationSharingManager?
    #endif
    #if os(iOS)
    /// Voice call manager — handles the LXST telephony destination
    /// registration, outgoing-call signaling, and inbound-link routing.
    /// Restored in commit 3 of the lxst-wiring batch, now talking through
    /// the Compat-layer Link bridge that AppServices wires here in
    /// configureTransportCallbacks.
    public private(set) var callManager: CallManager?
    #endif

    /// Python-backed Reticulum + LXMF stack. Created lazily on first
    /// `initialize(...)` and torn down on `shutdown()`. The Compat-layer
    /// `LXMRouter` and `ReticulumTransport` stubs delegate real work
    /// (announce listening, opportunistic LXMF send/receive) through this.
    public private(set) var backend: (any RnsBackend)?

    /// Generation-bound retain on the process-global activity monitor. Each
    /// active AppServices instance holds one lease; only the last release stops
    /// instrumentation.
    private let runtimeActivityMonitorLeaseHolder = RuntimeActivityMonitorLeaseHolder()

    /// Retain a successful operation's lease for this service instance. If a
    /// prior successful operation already retained one, the operation's extra
    /// lease is released rather than accumulated.
    private func retainRuntimeActivityMonitorLease(_ lease: RuntimeActivityMonitor.Lease) {
        guard runtimeActivityMonitorLeaseHolder.lease == nil else {
            RuntimeActivityMonitor.shared.release(lease)
            return
        }
        runtimeActivityMonitorLeaseHolder.lease = lease
    }

    private func releaseRuntimeActivityMonitorLease() {
        guard let lease = runtimeActivityMonitorLeaseHolder.lease else { return }
        runtimeActivityMonitorLeaseHolder.lease = nil
        RuntimeActivityMonitor.shared.release(lease)
    }

    private func requireActiveRuntimeForInterfaceMutation() throws {
        guard runtimeActivityMonitorLeaseHolder.lease != nil else {
            throw AppServicesError.transportNotConnected
        }
    }

    /// MainActor methods are reentrant at each await. This FIFO gate prevents
    /// initialize, shutdown, and reconnect from committing through one another.
    private var lifecycleOperationActive = false
    private var lifecycleOperationWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireLifecycleOperation() async {
        guard lifecycleOperationActive else {
            lifecycleOperationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleOperationWaiters.append(continuation)
        }
    }

    private func releaseLifecycleOperation() {
        guard !lifecycleOperationWaiters.isEmpty else {
            lifecycleOperationActive = false
            return
        }
        lifecycleOperationWaiters.removeFirst().resume()
    }

    func withLifecycleOperation<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        return try await operation()
    }

    /// The bound backend downcast to the Python impl — for Python-only wiring
    /// (BLE callback bridge and diagnose_* deep links). This API is compiled
    /// only into shipping because Model B does not own the concrete Python source.
    #if COLUMBA_RUNTIME_PYTHON
    public var pythonBackend: PythonRNSBackend? { backend as? PythonRNSBackend }
    #endif

    /// What the active backend supports — drives UI capability gating. `.unknown`
    /// (everything unsupported) until a backend is bound; re-evaluated via
    /// @Observable through `backend` when the backend changes.
    public var capabilities: BackendCapabilities { backend?.capabilities ?? .unknown }

    /// Background task that drains Python events (announces, inbound
    /// messages) into Columba's existing UI plumbing.
    private var pythonEventTask: Task<Void, Never>?
    private let pythonHostEventProcessingGate = PythonHostEventProcessingGate()

    func beginExclusivePythonHostEventProcessing() async -> Bool {
        await pythonHostEventProcessingGate.beginExclusive()
    }

    func endExclusivePythonHostEventProcessing() async {
        await pythonHostEventProcessingGate.endExclusive()
    }

    /// Tokens for the block-based NotificationCenter observers registered by
    /// `startPythonBackend()` (the lxma://test-* deep-link harness). Held so
    /// `shutdown()` can remove them — otherwise each restart cycle
    /// (identity-change / "Apply & Restart") would stack another set and fire
    /// every handler N times. Register via `addPythonObserver(_:_:)`.
    private var pythonNotificationObservers: [any NSObjectProtocol] = []

    /// Identity used to start the Python backend. Cached so the
    /// "Apply & Restart" flow can re-boot Python after the user edits
    /// interfaces, without making AppServices re-derive it.
    private var pythonStartIdentity: Identity?

    /// Display name passed to the Python backend on start. Cached for
    /// the restart path (same reason as pythonStartIdentity).
    private var pythonStartDisplayName: String = ""

    /// The interface entities currently live in the Python RNS stack, keyed by
    /// entity id. Seeded when the backend starts and updated incrementally by
    /// `applyInterfaceChanges()` as interfaces are hot-added / hot-removed.
    /// The status poll matches Python-reported sections against this set, so
    /// it must always reflect what's actually attached to Transport (not the
    /// launch-time snapshot — that was the source of the stale-status bug).
    private var pythonInterfaceEntities: [String: InterfaceEntity] = [:]

/// Periodic poller that mirrors Python's RNS.Transport interface state
    /// into the Compat TCPInterface stubs so the existing
    /// NetworkStatusView / InterfaceManagementScreen show correct
    /// connected/disconnected badges. Cancelled in `shutdown()`.
    private var pythonStatusPollTask: Task<Void, Never>?

    /// Last interface snapshot key we logged, so the poll only logs
    /// changes (not every 2s tick).
    private var lastInterfaceSnapshotKey: String = ""

    /// Same idea for the python-derived auxiliary list (peer interfaces
    /// like AutoInterfacePeer / BLEPeer that Python spawned dynamically).
    /// Init to sentinel so the first observation always logs (even if the
    /// count is 0 — that's useful too: "no peers discovered yet").
    private var lastAuxiliaryKey: String = "<uninitialized>"

    // MARK: - Telephony link bridge state
    //
    // Maps the Python RNS.Link IDs (bridge-allocated UInt64) to the Compat
    // Link objects that lxst-swift's Telephone state machine + CallManager
    // expect to talk to. Populated when Python emits a
    // link_state(state=established) event, drained when it emits a
    // link_state(state=closed) event.

    /// Active Compat Links keyed by Python's bridge linkId.
    private var activeLinksByLinkId: [UInt64: Link] = [:]

    /// Inbound-link callbacks registered by CallManager via
    /// transport.registerDestinationLinkCallback(for: telephonyDestHash).
    /// AppServices invokes these when an inbound link establishes on a
    /// matching destination. AppServices is @MainActor — all reads/writes
    /// happen on the main actor, no extra lock needed.
    private var destinationLinkCallbacks: [Data: @Sendable (Link) async -> Void] = [:]

    #if COLUMBA_RUNTIME_MODEL_B
    /// Network Extension tunnel manager.
    public private(set) var tunnelManager: TunnelManager?

    /// Extension frame reader for processing queued frames from the extension.
    private var extensionFrameReader: ExtensionFrameReader?

    /// Model-B first-launch gate. Set true while `startPythonBackend` suspends, before
    /// `backend.start()`, waiting for the user to approve + enable background delivery
    /// (the NE owns the node, so its VPN tunnel MUST be up first — on a fresh install it
    /// isn't, and proxying to it would otherwise spin for minutes). RootView shows
    /// `BackgroundDeliveryGateView` while this is true; `approveBackgroundDelivery()`
    /// clears it and resumes init. Persisted approval (returning users) skips the gate.
    public var needsBackgroundDeliveryApproval = false

    @ObservationIgnored
    private var backgroundDeliveryApprovalContinuation: CheckedContinuation<Void, Never>?

    private static let backgroundDeliveryEnabledKey = "background_delivery_enabled"
    #endif

    /// Darwin notification name used by on-device test instrumentation to
    /// trigger a manual announce. Posted from the host via
    /// `xcrun devicectl device notification post network.columba.test.announce`,
    /// since Maestro/idb can't drive the physical device. Not gated behind the
    /// Network Extension flag — the handler only calls `sendAllAnnounces`, which
    /// is meaningful regardless of the background-transport posture.
    private static let testAnnounceNotification = "network.columba.test.announce"

    /// Whether the test-announce Darwin observer has been registered. Guards
    /// against double-registration across the two `initialize` overloads /
    /// re-init cycles (the observer is process-global, keyed by `self`).
    private var testAnnounceObserverRegistered = false

    // MARK: - Interface Lookup

    /// Get a human-readable name for an interface ID.
    public func interfaceName(for interfaceId: String) async -> String? {
        await transport?.getInterfaceName(for: interfaceId)
    }

    // resolveReceivedInterface removed — interface is now stored per-message in the DB
    // via MessageRecord.receivingInterface, populated from packet.receivingInterface at delivery time.

    // MARK: - Observable Properties

    /// Connection state (observable for UI binding).
    ///
    /// True when the TCP interface is connected to the server.
    public private(set) var isConnected: Bool = false

    /// Human-readable connection error message (nil when connected or connecting).
    ///
    /// Set when the TCP interface reports a failure (e.g., unreachable host,
    /// timeout, connection refused). Cleared on successful connection.
    public private(set) var connectionError: String?

    /// Whether the interface is actively reconnecting after a failure.
    public private(set) var isReconnecting: Bool = false

    /// Local LXMF delivery destination hash (16 bytes).
    ///
    /// This is the hash that other peers use to address messages to us.
    /// Computed as: `Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])`
    ///
    /// Returns empty Data if identity is not yet initialized.
    public var localIdentityHash: Data {
        guard let identity = identity else {
            return Data()
        }
        return Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])
    }

    /// Cached hex string of local identity hash for display.
    public private(set) var localIdentityHashHex: String = ""

    // MARK: - Internal State

    /// Logger for debugging service initialization.
    private let logger = Logger(subsystem: "network.columba.Columba", category: "AppServices")

    /// Static logger for use in static methods (identity loading).
    private static let sLogger = Logger(subsystem: "network.columba.Columba", category: "AppServices")


    /// Interface state observer task (cancelled on deinit).
    private var stateObserverTask: Task<Void, Never>?

    /// Registry of interface ids that were spawned as peer-children of an
    /// AutoInterface / BLEInterface / MPCInterface parent, recorded from
    /// `onInterfacePeerSpawned`. Used to attribute the subsequent
    /// `onInterfaceConnected` event for the same id to the peer-spawned
    /// trigger rather than the tcp-reconnect trigger — see
    /// `AutoAnnouncePolicy.shouldFireOnInterfaceConnected(isPeerChild:)`.
    ///
    /// Synchronous lock-protected (rather than actor-isolated) so the
    /// peer-spawned closure can commit a record before any `await`
    /// suspension. If both record and lookup hopped to the main actor,
    /// Swift's task scheduler would not guarantee record-before-lookup
    /// ordering: both events fire from independent reticulum-swift Tasks,
    /// and a connected-event Task could win the actor enqueue race even
    /// though peer-spawn fired first in wall-clock time. The lock makes
    /// the record a synchronous, atomic side-effect of the peer-spawned
    /// callback's first line, before any await.
    ///
    /// Grows monotonically — entries are not removed on peer departure.
    /// Peer-children are typically dozens at most on a Columba mesh, so
    /// memory is a non-concern. If that ever becomes meaningful, add
    /// removal in a `setOnInterfacePeerRemoved` callback when reticulum-swift
    /// exposes one.
    private let peerChildRegistry = PeerChildInterfaceRegistry()

    // MARK: - Identity Persistence Constants

    /// Keychain service identifier for storing identity.
    private static let keychainService = "com.columba.identity"

    /// Keychain account identifier for storing identity.
    private static let keychainAccount = "reticulum-identity"

    /// Suffix of the shared keychain access group (app + Network Extension). The full
    /// group is `<team-id-prefix>.<suffix>` — see ColumbaApp.entitlements.
    private static let keychainGroupSuffix = "network.columba.Columba.shared"

    /// The shared keychain access group, resolved at runtime so the team-id prefix is
    /// NOT hardcoded in source (no deployment-identifying PII). Returns nil on unsigned /
    /// simulator builds where the keychain-access-groups entitlement isn't enforced; in
    /// that case identity ops fall back to the app's default (unshared) keychain group.
    private static func sharedKeychainAccessGroup() -> String? {
        guard let prefix = keychainAccessGroupPrefix() else { return nil }
        return "\(prefix).\(keychainGroupSuffix)"
    }

    /// Resolve the app-identifier (team-id) prefix by reading the access group the system
    /// assigns to a fresh generic-password item (the standard "bundle seed id" probe).
    private static func keychainAccessGroupPrefix() -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "columba.bundleSeedProbe",
            kSecAttrService as String: "columba.bundleSeedProbe",
        ]
        // Ensure the probe item exists. Add WITH a value (a value-less generic-
        // password Add can fail) and tolerate an existing item; the system assigns
        // the app's default keychain access group ("<teamPrefix>.<bundle-id>").
        // NB: the previous code read the group from SecItemAdd's RESULT, which
        // omits kSecAttrAccessGroup — so the probe always returned nil and the
        // shared group was never resolved (A3 silently fell back to the default
        // group, unreachable by the NE). Read it back via CopyMatching instead.
        var addDict = base
        addDict[kSecValueData as String] = Data()
        let addStatus = SecItemAdd(addDict as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            DiagLog.log("[IDENTITY] bundleSeedProbe add failed: \(addStatus)")
            return nil
        }
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let copyStatus = SecItemCopyMatching(query as CFDictionary, &result)
        // The probe item exists ONLY to read the system-assigned access group; delete it
        // now (regardless of the read result) so it doesn't accumulate in the user's
        // keychain for the lifetime of the install. Re-resolution re-adds it cheaply.
        SecItemDelete(base as CFDictionary)
        guard copyStatus == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = group.components(separatedBy: ".").first,
              !prefix.isEmpty else {
            DiagLog.log("[IDENTITY] bundleSeedProbe read failed: \(copyStatus)")
            return nil
        }
        return prefix
    }

    /// File path for identity persistence (fallback when Keychain unavailable).
    private static var identityFilePath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let columbaDir = appSupport.appendingPathComponent("Columba", isDirectory: true)
        // Create directory if needed
        try? FileManager.default.createDirectory(at: columbaDir, withIntermediateDirectories: true)
        return columbaDir.appendingPathComponent("identity.key")
    }

    /// File path for LXMF database persistence (legacy, used by single-identity fallback).
    private static var databaseFilePath: String {
        databaseFilePath(for: nil)
    }

    /// File path for LXMF database for a specific identity.
    ///
    /// - Parameter identityHash: Identity hash hex string, or nil for legacy `lxmf.db`
    /// - Returns: Full path to the database file
    private static func databaseFilePath(for identityHash: String?) -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let columbaDir = appSupport.appendingPathComponent("Columba", isDirectory: true)
        try? FileManager.default.createDirectory(at: columbaDir, withIntermediateDirectories: true)
        let filename = identityHash.map { "lxmf_\($0).db" } ?? "lxmf.db"
        return columbaDir.appendingPathComponent(filename).path
    }

    /// File path for the GRDB-backed canonical LXMF store (`lxmf-swift.db`).
    ///
    /// Under Model B this store lives in the SHARED App-Group container so the app
    /// and the Network Extension converge on ONE store, computed via the shared
    /// `AppGroupPaths` helper (the single source of truth both sides delegate to —
    /// see `AppGroupPaths.swift`). The layout is
    /// `<App-Group container>/Columba/python-<identityHashHex>/lxmf-swift.db`, and
    /// `identityHashHex` is `identity.hexHash` (the raw identity hash — NOT the
    /// lxmf.delivery destination hash).
    ///
    /// Falls back to the legacy process-local Application Support path
    /// (`<appSupport>/Columba/python-<hash>/lxmf-swift.db`) ONLY when the App-Group
    /// container is unavailable (unsigned / simulator builds with no App-Group
    /// entitlement); on such builds the NE isn't running anyway, so there is no
    /// store to converge with. One-time migration of an existing process-local
    /// store into the App-Group container is handled by
    /// `migrateLXMFDatabaseToAppGroupIfNeeded(identityHashHex:)`, which callers run
    /// before opening the store.
    ///
    /// - Parameter identityHashHex: Hex of the raw identity hash (`identity.hexHash`).
    /// - Returns: Full path to `lxmf-swift.db` for that identity.
    static func grdbDatabaseFilePath(for identityHashHex: String) -> String {
        if let url = AppGroupPaths.lxmfDatabaseURL(identityHashHex: identityHashHex) {
            return url.path
        }
        return legacyProcessLocalGRDBDatabaseFilePath(for: identityHashHex)
    }

    /// Legacy process-local path for `lxmf-swift.db`
    /// (`<Application Support>/Columba/python-<identityHashHex>/lxmf-swift.db`).
    /// This is the location the store lived at BEFORE the A2 move to the App-Group
    /// container; retained as (a) the fallback when the App-Group container is
    /// unavailable and (b) the migration source in
    /// `migrateLXMFDatabaseToAppGroupIfNeeded(identityHashHex:)`.
    private static func legacyProcessLocalGRDBDatabaseFilePath(for identityHashHex: String) -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pyDir = appSupport.appendingPathComponent("Columba/python-\(identityHashHex)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pyDir, withIntermediateDirectories: true)
        return pyDir.appendingPathComponent("lxmf-swift.db").path
    }

    /// One-time migration of the canonical LXMF GRDB store from the legacy
    /// process-local Application Support path to the SHARED App-Group container, so
    /// an existing install's message history carries over when the store relocates
    /// for Model B (A2). Idempotent and guarded by a `SharedDefaults` flag.
    ///
    /// Behavior: if the flag is unset AND the OLD process-local `lxmf-swift.db`
    /// exists AND the NEW App-Group `lxmf-swift.db` does NOT exist, copy all three
    /// SQLite WAL-mode files (`lxmf-swift.db`, `-wal`, `-shm`) into the App-Group
    /// container, then set the flag. The old files are LEFT in place as a fallback
    /// (we only flip the flag). Must be called BEFORE the store is opened
    /// (`MessageRepository(grdbPath:)`), so the copied files are in place when GRDB
    /// first attaches. No-op (just flips the flag, if not already set) when there's
    /// nothing to migrate or when the App-Group container is unavailable.
    ///
    /// - Parameter identityHashHex: Hex of the raw identity hash (`identity.hexHash`).
    static func migrateLXMFDatabaseToAppGroupIfNeeded(identityHashHex: String) {
        // Idempotent: once migrated (or determined a no-op), never run again.
        guard !SharedDefaults.suite.bool(forKey: lxmfDatabaseMigratedToAppGroupKey) else {
            return
        }

        // New (App-Group) destination. nil ⇒ container unavailable (unsigned /
        // simulator): nothing to migrate to; leave the flag unset so a later
        // signed run can still migrate.
        guard let newURL = AppGroupPaths.lxmfDatabaseURL(identityHashHex: identityHashHex) else {
            return
        }

        let fm = FileManager.default
        let oldPath = legacyProcessLocalGRDBDatabaseFilePath(for: identityHashHex)
        let oldURL = URL(fileURLWithPath: oldPath)

        // If the old store doesn't exist, there's nothing to copy (fresh install,
        // or already running on the App-Group store). Mark migrated so we don't
        // re-check on every launch.
        guard fm.fileExists(atPath: oldURL.path) else {
            SharedDefaults.suite.set(true, forKey: lxmfDatabaseMigratedToAppGroupKey)
            return
        }

        // If the new store already exists, do NOT clobber it — the App-Group store
        // is authoritative. Just flip the flag.
        guard !fm.fileExists(atPath: newURL.path) else {
            SharedDefaults.suite.set(true, forKey: lxmfDatabaseMigratedToAppGroupKey)
            return
        }

        // Copy the main DB plus the WAL sidecar files. Copying -wal/-shm matters
        // for a WAL-mode SQLite DB: recent committed pages may live only in the
        // WAL until a checkpoint folds them into the main file, so omitting them
        // could silently drop the newest messages.
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: oldURL.path + suffix)
            let dst = URL(fileURLWithPath: newURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                // Destination dir already created by AppGroupPaths.lxmfDatabaseURL.
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
            } catch {
                // Best-effort: log and continue. We deliberately do NOT set the
                // flag on a copy failure so a subsequent launch can retry. The old
                // files are untouched, so the worst case is the app opens an empty
                // App-Group store this run and retries the copy next launch.
                sLogger.warning("[A2-MIGRATE] copy of lxmf-swift.db\(suffix, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        SharedDefaults.suite.set(true, forKey: lxmfDatabaseMigratedToAppGroupKey)
        sLogger.info("[A2-MIGRATE] migrated lxmf-swift.db to the App-Group container")
    }

    /// `SharedDefaults` flag key recording that the one-time A2 migration of
    /// `lxmf-swift.db` into the App-Group container has run (see
    /// `migrateLXMFDatabaseToAppGroupIfNeeded(identityHashHex:)`).
    private static let lxmfDatabaseMigratedToAppGroupKey = "lxmf_db_migrated_to_appgroup"

    /// File path for ratchet key storage for a specific identity.
    ///
    /// - Parameter identityHash: Hex hash of the identity
    /// - Returns: Full path to the ratchet persistence file
    private static func ratchetStoragePath(for identityHash: String) -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let columbaDir = appSupport.appendingPathComponent("Columba", isDirectory: true)
        try? FileManager.default.createDirectory(at: columbaDir, withIntermediateDirectories: true)
        return columbaDir.appendingPathComponent("ratchets_\(identityHash)").path
    }

    /// File path for path table database persistence.
    private static var pathTableFilePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let columbaDir = appSupport.appendingPathComponent("Columba", isDirectory: true)
        // Create directory if needed
        try? FileManager.default.createDirectory(at: columbaDir, withIntermediateDirectories: true)
        return columbaDir.appendingPathComponent("paths.db").path
    }

    // MARK: - Identity Persistence

    /// Load identity from persistent storage or create a new one.
    ///
    /// Tries in order:
    /// 1. Keychain (secure, preferred)
    /// 2. File-based storage (fallback for unsigned builds)
    /// 3. Creates new identity and saves it
    ///
    /// Model B: make the active identity reachable by the in-NE node, regardless of
    /// which init path established it. Resolve the shared keychain group (the app
    /// runs unlocked, so its probe works), share it via the App Group (the NE can't
    /// reliably probe while locked), and persist the identity into that shared group
    /// so the NE can load it (`...AfterFirstUnlockThisDeviceOnly`, NE-readable while
    /// locked after first unlock). No-op on unsigned/simulator builds (group == nil).
    #if COLUMBA_RUNTIME_MODEL_B
    private static func shareIdentityForModelB(_ identity: Identity) {
        guard let group = sharedKeychainAccessGroup() else {
            DiagLog.log("[IDENTITY] Model B share: shared keychain group unresolved")
            return
        }
        SharedDefaults.suite.set(group, forKey: "resolvedSharedKeychainGroup")
        do {
            try identity.saveToKeychain(service: keychainService, account: keychainAccount, accessGroup: group)
            DiagLog.log("[IDENTITY] Model B share: group resolved + identity persisted to shared keychain")
        } catch {
            DiagLog.log("[IDENTITY] Model B share: keychain save failed: \(error.localizedDescription)")
        }
    }
    #endif

    /// - Returns: The loaded or newly created identity
    private static func loadOrCreateIdentity() -> Identity {
        // Shared group so the Network Extension reads the SAME identity (Model B).
        // nil on unsigned/simulator builds → falls back to the app's default group.
        let group = sharedKeychainAccessGroup()
        DiagLog.log("[IDENTITY] shared keychain group resolved=\(group != nil)")
        // Hand the resolved group to the NE via the App Group: the in-NE keychain
        // probe is unreliable while the device is locked (exactly when background
        // delivery must run) and before the app has ever launched, so the NE reads
        // this app-resolved value instead of probing.
        if let group {
            SharedDefaults.suite.set(group, forKey: "resolvedSharedKeychainGroup")
        }

        // 1. Keychain, shared group (the group the NE also reads).
        do {
            if let stored = try Identity.loadFromKeychain(
                service: keychainService, account: keychainAccount, accessGroup: group
            ) {
                sLogger.info("[IDENTITY] Loaded from Keychain (shared group)")
                return stored
            }
        } catch {
            sLogger.warning("[IDENTITY] Keychain load error: \(error.localizedDescription)")
        }

        // 1b. One-time migration: an identity stored before the shared-group change lives
        //     in the app's DEFAULT keychain group, unreachable by the NE. Move it into the
        //     shared group, then delete the legacy copy. Only meaningful on signed builds
        //     (group != nil).
        if group != nil {
            if let legacy = try? Identity.loadFromKeychain(
                service: keychainService, account: keychainAccount, accessGroup: nil
            ) {
                try? legacy.saveToKeychain(
                    service: keychainService, account: keychainAccount, accessGroup: group
                )
                _ = Identity.deleteFromKeychain(
                    service: keychainService, account: keychainAccount, accessGroup: nil
                )
                sLogger.info("[IDENTITY] Migrated identity into the shared keychain group")
                return legacy
            }
        }

        // 2. File-based storage (fallback for unsigned builds where keychain is unavailable).
        if let stored = loadIdentityFromFile() {
            sLogger.info("[IDENTITY] Loaded from file")
            return stored
        }

        // 3. Create a new identity and save it to the shared keychain group.
        let created = Identity()
        sLogger.info("[IDENTITY] Created new identity")
        do {
            try created.saveToKeychain(
                service: keychainService, account: keychainAccount, accessGroup: group
            )
            // Keychain is the source of truth on signed builds; remove any stale plaintext
            // fallback file so an unencrypted private key never lingers at rest.
            removeIdentityFile()
            return created
        } catch {
            sLogger.warning("[IDENTITY] Keychain save failed: \(error.localizedDescription)")
        }

        // Fall back to file storage (dev/unsigned only).
        _ = saveIdentityToFile(created)
        return created
    }

    /// Load identity from file.
    private static func loadIdentityFromFile() -> Identity? {
        let path = identityFilePath
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: path)
            return try Identity(privateKeyBytes: data)
        } catch {
            sLogger.warning("[IDENTITY] File load error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save identity to file (dev/unsigned fallback only).
    private static func saveIdentityToFile(_ identity: Identity) -> Bool {
        do {
            let data = try identity.exportPrivateKeys()
            try data.write(to: identityFilePath, options: .atomic)
            #if os(iOS)
            // Even the fallback must not leave the private key at default protection;
            // require at least first-unlock so it isn't readable on a locked cold device.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: identityFilePath.path
            )
            #endif
            return true
        } catch {
            sLogger.warning("[IDENTITY] File save error: \(error.localizedDescription)")
            return false
        }
    }

    /// Remove the plaintext identity fallback file (called once the keychain — the
    /// source of truth on signed builds — holds the identity, so an unencrypted private
    /// key doesn't linger at rest).
    private static func removeIdentityFile() {
        try? FileManager.default.removeItem(at: identityFilePath)
    }

    // MARK: - Initialization

    /// Create uninitialized AppServices.
    ///
    /// Call `initialize(tcpServerAddress:)` to set up all components.
    public init() {}

    /// Initialize all LXMF components.
    ///
    /// This async method sets up the complete LXMF stack:
    /// 1. Creates a new random Identity
    /// 2. Creates PathTable for route management
    /// 3. Creates ReticulumTransport with the PathTable
    /// 4. Creates LXMFDatabase (in-memory for now)
    /// 5. Creates LXMRouter with identity and database
    /// 6. Creates and registers LXMF delivery Destination
    /// 7. Parses server address and creates TCPInterface
    /// 8. Adds interface to transport
    /// 9. Sets transport on router
    ///
    /// - Parameter tcpServerAddress: TCP server address (e.g., "tcp://10.0.0.1:4242" or "10.0.0.1:4242")
    /// - Throws: InterfaceError, DatabaseError, or other initialization errors
    public func initialize(tcpServerAddress: String) async throws {
        try await withLifecycleOperation {
            try await initializeUnlocked(tcpServerAddress: tcpServerAddress)
        }
    }

    private func initializeUnlocked(tcpServerAddress: String) async throws {
        DiagLog.log("[STARTUP] AppServices initialization beginning")
        let monitorLease = RuntimeActivityMonitor.shared.acquire()
        var initializationSucceeded = false
        defer {
            if initializationSucceeded {
                retainRuntimeActivityMonitorLease(monitorLease)
            } else {
                RuntimeActivityMonitor.shared.release(monitorLease)
            }
        }
        DiagLog.log("[INIT] Starting with TCP server: \(tcpServerAddress)")

        // 1. Load identity from persistent storage (try Keychain first, then file)
        let newIdentity: Identity = Self.loadOrCreateIdentity()
        self.identity = newIdentity
        self.localIdentityHashHex = localIdentityHash.map { String(format: "%02x", $0) }.joined()

        // 2. Create path table for routing with persistence
        let pathDbPath = Self.pathTableFilePath
        let newPathTable = try PathTable(databasePath: pathDbPath)
        self.pathTable = newPathTable

        // 3. Create transport with path table
        let newTransport = ReticulumTransport(pathTable: newPathTable)
        self.transport = newTransport
        await configureTransportCallbacks(newTransport)
        await newTransport.registerPathRequestHandler()

        // 4. Create persistent LXMF database (RNSAPI Compat store — sender-name
        //    lookups for IncomingMessageHandler / CallManager).
        let dbPath = Self.databaseFilePath
        let newDatabase = try LXMFDatabase(path: dbPath)
        self.database = newDatabase

        // 4b. Open the GRDB canonical store the Swift/NE backend writes, so the
        //     UI reads the same messages. Keyed by the raw identity hash (the
        //     same `identity.hexHash` startPythonBackend derives configDir from).
        //     The store now lives in the shared App-Group container so the app and
        //     the NE converge on ONE store (Model B / A2); migrate any pre-existing
        //     process-local store over BEFORE opening it.
        Self.migrateLXMFDatabaseToAppGroupIfNeeded(identityHashHex: newIdentity.hexHash)
        let grdbPath = Self.grdbDatabaseFilePath(for: newIdentity.hexHash)
        self.grdbDatabasePath = grdbPath
        let messageRepository = try MessageRepository(grdbPath: grdbPath)
        self.messageRepository = messageRepository
        let recoveredRetryCount = try await messageRepository.recoverInterruptedRetries()
        if recoveredRetryCount > 0 {
            logger.warning("Recovered \(recoveredRetryCount, privacy: .public) interrupted message retries")
        }

        // 5. Create LXMRouter with identity and database path
        let newRouter = try await LXMRouter(identity: newIdentity, databasePath: dbPath)
        self.router = newRouter

        // 6. Create and register LXMF delivery destination
        let newDestination = Destination(
            identity: newIdentity,
            appName: "lxmf",
            aspects: ["delivery"],
            type: .single,
            direction: .in
        )
        self.deliveryDestination = newDestination
        await newTransport.registerDestination(newDestination)

        // 6b. Enable ratchets for forward secrecy
        let identityHashHex = newIdentity.hexHash
        let ratchetPath = Self.ratchetStoragePath(for: identityHashHex)
        try await newDestination.enableRatchets(storagePath: ratchetPath)

        // 7. Set transport on router for message delivery (before interfaces, so
        //    router is ready to receive packets as soon as any interface connects)
        await newRouter.setTransport(newTransport)
        await newRouter.setRatchetManager(newDestination.ratchetManager)

        #if os(iOS)
        // 7b. Initialize call manager BEFORE interfaces so that autoAnnounce()
        //     (triggered by onInterfaceAdded) can send the telephony announce.
        DiagLog.log("[INIT] Step 7b: creating CallManager")
        let cm = CallManager()
        await cm.initialize(identity: newIdentity, transport: newTransport, pathTable: newPathTable, database: newDatabase)
        self.callManager = cm
        DiagLog.log("[INIT] Step 7b done, telephonyDest=\(cm.telephonyDestination?.hexHash ?? "nil")")
        #endif

        // 8. Parse server address and create TCP interface (non-fatal — app works offline)
        if let (host, port) = parseHostPort(tcpServerAddress) {
            let config = InterfaceConfig(
                id: "tcp-server",
                name: "TCP Server",
                type: .tcp,
                enabled: true,
                mode: .full,
                host: host,
                port: port
            )
            do {
                let newInterface = try TCPInterface(config: config)
                tcpInterfaces["tcp-server"] = newInterface
                try await newTransport.addInterface(newInterface)
                // Record the applied endpoint only after the interface
                // has been successfully attached. See the matching catch
                // block below for why this ordering matters.
                tcpEndpoints["tcp-server"] = TCPEndpoint(host: host, port: port)
            } catch {
                // Initialization is "non-fatal" with respect to TCP — the
                // rest of init proceeds without it, and the user can
                // retry via reconnectTCPOnly. But that retry routes
                // through connectTCPInterface, whose new idempotency
                // guard would silently no-op if a stale tcpEndpoints
                // entry survived this catch. Roll back any partial
                // dictionary writes so a same-address retry isn't
                // stuck.
                tcpInterfaces.removeValue(forKey: "tcp-server")
                tcpEndpoints.removeValue(forKey: "tcp-server")
                logger.warning("TCP interface failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 9. Register delivery destination with router to receive inbound LXMF messages
        try await newRouter.registerDeliveryDestination(newDestination)

        // Start monitoring interface state for UI updates
        startStateObserver()

        // 10. Restore propagation preferences before backend startup. Listener,
        // periodic, and auto-announce tasks are activated only after the backend
        // and persisted propagation node are ready, so a failed retry cannot leak
        // initialization-owned tasks.
        let propManager = PropagationNodeManager(appServices: self)
        self.propagationManager = propManager
        await propManager.loadPreferences()

        try await InitializationLifecycleActivation.run(
            readiness: {
                // The Compat-layer LXMRouter / Transport are stubs; real network
                // I/O happens through PythonBridge.
                try await self.startPythonBackend(
                    identity: newIdentity,
                    identityHashHex: newIdentity.hexHash,
                    router: newRouter,
                    interfaces: InterfaceRepository().getEnabledInterfaces(),
                    displayName: ""
                )
            },
            activate: {
                self.activateInitializationManagers(propManager)
            }
        )

        // On-device test instrumentation: listen for the test-announce Darwin
        // notification now that the backend is up (see helper docs). Idempotent.
        registerTestAnnounceObserver()

        initializationSucceeded = true
        logger.info("Initialization complete")
    }

    // MARK: - Python backend

    #if DEBUG
    /// Register a block-based NotificationCenter observer and retain its token
    /// in `pythonNotificationObservers` so `shutdown()` can remove it. Use this
    /// for every observer added by `startPythonBackend()` — keeping the tokens
    /// is what lets a restart cycle tear the old observers down instead of
    /// stacking duplicates. DEBUG-only: its sole callers are the `lxma://test-*`
    /// observers (`shutdown()` still tears down the array unconditionally).
    private func addPythonObserver(
        _ name: String,
        _ block: @escaping @Sendable (Notification) -> Void
    ) {
        pythonNotificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main, using: block
            )
        )
    }
    #endif

    /// Boot the embedded Python RNS stack and hook `LXMRouter.sendHook` so
    /// outbound LXMF sends go through Python. Spawns a Task that drains
    /// Python events and feeds them into Columba's path table / inbound
    /// message handler. Idempotent — does nothing if already started.
    ///
    /// The RNS config file is written from `interfaces` (the user's enabled
    /// `InterfaceEntity` records from `InterfaceRepository`). No host/port
    /// is hardcoded — if `interfaces` is empty the app starts offline and
    /// the user adds an interface in Settings → Manage Interfaces.
    #if COLUMBA_RUNTIME_MODEL_B
    /// Create + wire the tunnel manager exactly once (idempotent). Called by
    /// `initialize()` and by the onboarding background-delivery step, which may bring
    /// the tunnel up before `initialize()` runs.
    private func ensureTunnelManager() async {
        guard tunnelManager == nil else { return }
        let tunnel = TunnelManager()
        self.tunnelManager = tunnel
        // Wire tunnel state -> per-interface tunnel-mode coordination (see initialize()).
        tunnel.onStatusChange = { [weak self] newStatus in
            guard let self else { return }
            Task { @MainActor in
                switch newStatus {
                case .connected:
                    await self.applyTunnelModeToInterfaces(active: true)
                case .disconnected, .invalid:
                    await self.applyTunnelModeToInterfaces(active: false)
                default:
                    break
                }
            }
        }
        await tunnel.load()
    }

    /// Onboarding's in-flow "Enable Background Delivery" step (Model B). Shares the
    /// active identity into the NE-readable keychain, brings the VPN tunnel up (the
    /// iOS "Allow" prompt fires here), and persists approval so the post-onboarding
    /// init takes the silent-reconnect path (no second gate). Returns whether the
    /// tunnel connected; the page surfaces an error + retry on `false`. No-op-ish on
    /// simulator/unsigned builds (the shared-keychain group is nil and the tunnel
    /// won't truly connect there).
    @discardableResult
    public func enableBackgroundDeliveryForOnboarding(identity: Identity) async -> Bool {
        Self.shareIdentityForModelB(identity)
        await ensureTunnelManager()
        guard let tunnel = tunnelManager else { return false }
        do {
            try await tunnel.install()
            try await tunnel.start()
        } catch {
            DiagLog.log("[TUNNEL-GATE] onboarding enable failed: \(error)")
            return false
        }
        guard await tunnel.waitUntilConnected(timeoutMs: 25_000) else {
            DiagLog.log("[TUNNEL-GATE] onboarding enable: tunnel did not connect (approval denied?)")
            return false
        }
        SharedDefaults.suite.set(true, forKey: Self.backgroundDeliveryEnabledKey)
        DiagLog.log("[TUNNEL-GATE] onboarding enable: tunnel connected + approval persisted")
        return true
    }

    /// Ensure the NE/VPN tunnel is connected before the Model-B proxy backend starts.
    ///
    /// Returning users (approval persisted) get a SILENT bring-up — `install()` is a
    /// no-op re-save, `start()` reconnects, iOS does not re-prompt. First run (or if the
    /// silent bring-up can't connect, e.g. the user revoked the VPN in iOS Settings)
    /// suspends here and shows `BackgroundDeliveryGateView`; `approveBackgroundDelivery()`
    /// resumes us once the tunnel is up. This is what keeps `backend.start()` from
    /// spinning minutes on a fresh install.
    private func ensureBackgroundDeliveryTunnel() async {
        guard let tunnel = tunnelManager else {
            DiagLog.log("[TUNNEL-GATE] no tunnel manager — skipping (degraded)")
            return
        }
        if SharedDefaults.suite.bool(forKey: Self.backgroundDeliveryEnabledKey) {
            // Returning user: bring the tunnel up without prompting.
            try? await tunnel.install()
            try? await tunnel.start()
            if await tunnel.waitUntilConnected(timeoutMs: 20_000) {
                DiagLog.log("[TUNNEL-GATE] returning user — tunnel reconnected")
                return
            }
            DiagLog.log("[TUNNEL-GATE] returning user — silent reconnect failed; showing gate")
        }
        // First run, or silent reconnect failed → require explicit approval via the gate.
        DiagLog.log("[TUNNEL-GATE] awaiting background-delivery approval (showing gate)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            backgroundDeliveryApprovalContinuation = cont
            needsBackgroundDeliveryApproval = true
        }
        DiagLog.log("[TUNNEL-GATE] approval received — resuming init")
    }

    /// Gate-flow entry point ONLY (called by `BackgroundDeliveryGateView`'s Enable
    /// button — `internal` to keep it out of the public API so it can't be invoked
    /// outside the gate, where the suspended-init continuation it resumes wouldn't
    /// exist). Installs + starts the tunnel (the first `install()` fires the iOS
    /// VPN-approval prompt), waits for it to connect, persists the approval, then
    /// resumes the suspended init. Returns whether the tunnel connected — the gate
    /// surfaces an error + retry on `false` (e.g. the user tapped "Don't Allow"),
    /// WITHOUT resuming init, so the user can try again. (The non-gate "enable
    /// background delivery" path is the separate `enableBackgroundDeliveryForOnboarding`.)
    @discardableResult
    func approveBackgroundDelivery() async -> Bool {
        guard let tunnel = tunnelManager else { return false }
        do {
            try await tunnel.install()
            try await tunnel.start()
        } catch {
            DiagLog.log("[TUNNEL-GATE] enable failed: \(error)")
            return false
        }
        guard await tunnel.waitUntilConnected(timeoutMs: 25_000) else {
            DiagLog.log("[TUNNEL-GATE] enable: tunnel did not connect (approval denied?)")
            return false
        }
        SharedDefaults.suite.set(true, forKey: Self.backgroundDeliveryEnabledKey)
        needsBackgroundDeliveryApproval = false
        backgroundDeliveryApprovalContinuation?.resume()
        backgroundDeliveryApprovalContinuation = nil
        DiagLog.log("[TUNNEL-GATE] enable: tunnel connected + approval persisted")
        return true
    }
    #endif

    private func startPythonBackend(
        identity: Identity,
        identityHashHex: String,
        router: LXMRouter,
        interfaces: [InterfaceEntity],
        displayName: String
    ) async throws {
        DiagLog.log("[RNS] backend start entered with \(interfaces.count) interfaces")
        if backend != nil {
            DiagLog.log("[RNS] already started")
            return
        }
        // Cache the start args so restartPythonBackend() can re-invoke
        // this method after the user applies interface changes.
        self.pythonStartIdentity = identity
        self.pythonStartDisplayName = displayName

        // Model B (Track C3): when `BackendPreference.modelB` is on,
        // `BackendFactory.make` returns the thin-client `ProxyRnsBackend`, which
        // needs a live IPC transport to the NE's `NEReticulumNode`. Inject
        // `TunnelManager.proxySend` (wraps `sendProviderMessage`). Resolved LAZILY
        // (read `self.tunnelManager` at send-time, not make-time) so it works even
        // though one of the two init paths creates the tunnel after this call. The
        // closure is `@Sendable`; it hops to the @MainActor `AppServices` to read
        // the tunnel, then calls the non-isolated async `proxySend`. When Model B
        // is off (the default) `make` ignores `proxySend` and returns the
        // Swift/Python backend, so this wiring is inert until the flag is flipped.
        #if COLUMBA_RUNTIME_MODEL_B
        let proxySend: @Sendable (Data) async -> Data? = { [weak self] data in
            // Read the @MainActor-isolated `tunnelManager` via `MainActor.run`
            // (the established pattern in this file for crossing into MainActor
            // state from a Sendable async context — see `applyPythonInterfaceStatus`
            // callers). `TunnelManager` is Sendable and `proxySend` is non-isolated,
            // so the IPC call itself needs no hop.
            guard let tunnel = await MainActor.run(body: { self?.tunnelManager }) else {
                return nil
            }
            return await tunnel.proxySend(data)
        }
        let backend = BackendFactory.make(proxySend: proxySend)
        #else
        let backend = BackendFactory.make()
        #endif
        self.backend = backend

        #if COLUMBA_RUNTIME_MODEL_B
        // Model B: CoreBluetooth lives in the app process, but it is optional. Do not
        // construct the driver (and trigger iOS authorization) unless onboarding or
        // Settings recorded an explicit transport opt-in.
        if ModelBBLEService.shouldStart {
            ModelBBLEService.shared.start(identityHash: identity.hash)
        } else {
            DiagLog.log("[BLE] Model B BLE service skipped — no explicit user opt-in")
        }
        #endif

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pyDir = appSupport.appendingPathComponent("Columba/python-\(identityHashHex)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pyDir, withIntermediateDirectories: true)
        let configDir = pyDir.path
        let identityFile = pyDir.appendingPathComponent("identity.bin").path
        DiagLog.log("[RNS] configDir=\(configDir)")

        // Deploy iOS native-transport custom interface files BEFORE Python boots so RNS's
        // external-interface loader can `exec()` them when reading config.
        // Always copied (regardless of whether BLE is enabled in the
        // current config) so a later restart with BLE-enabled config finds
        // them without an extra deployment step.
        deployIOSBLEPythonFilesIfPossible(configDir: pyDir)

        // Generate the RNS config from user-saved interface entities. The
        // file lands at `<configDir>/config` where Python's
        // `RNS.Reticulum(config_dir)` will pick it up. Transport mode is
        // read from the App Group UserDefaults (toggled in
        // Settings → Advanced → Transport Mode); changing it requires
        // tapping Apply & Restart on the same screen.
        let transportEnabled = SharedDefaults.suite.bool(forKey: "transport_enabled")
        let configText = PythonConfigWriter.write(interfaces: interfaces, enableTransport: transportEnabled)
        let configFile = pyDir.appendingPathComponent("config")
        do {
            try configText.write(to: configFile, atomically: true, encoding: .utf8)
            DiagLog.log("[RNS] wrote config (\(configText.count) bytes, \(interfaces.count) interfaces)")
        } catch {
            DiagLog.log("[RNS] config write FAILED: \(error)")
        }

        let identityBytes = try? identity.exportPrivateKeys()
        DiagLog.log("[RNS] identityBytes=\(identityBytes?.count ?? -1)")

        #if COLUMBA_RUNTIME_PYTHON
        // IOSBLEInterface starts synchronously inside backend.start(). Install
        // the native callback sink first so discoveries and handshakes that
        // arrive during Python startup are not lost before the later UI
        // interface pass runs.
        if let pythonBackend {
            columbaBLEForceLinkNativeBindings()
            SwiftBLEBridge.shared.setCallbackInvoker(
                PythonBLECallbackBridge(pythonBridge: pythonBackend.pythonBridge)
            )
            SwiftBLEBridge.shared.setIdentity(identity.hash)
        }
        #endif

        #if COLUMBA_RUNTIME_MODEL_B
        // Model B: `backend` is the thin-client proxy; `backend.start()` round-trips to
        // the NE node over the VPN tunnel session, so the tunnel MUST be connected first.
        // A fresh install has no VPN config at all — without this, start() would spin
        // ~30×8s on a dead session (the "stuck on Connecting to network… for minutes"
        // bug). Bring the tunnel up, gating first-run on the background-delivery approval
        // gate so the iOS VPN prompt is a deliberate user step, not a silent hang.
        await ensureBackgroundDeliveryTunnel()
        #endif

        do {
            DiagLog.log("[RNS] calling backend.start()")
            let info = try await backend.start(
                .init(
                    configDir: configDir,
                    identityPath: identityFile,
                    displayName: displayName,
                    identityBytes: identityBytes
                )
            )
            DiagLog.log("[RNS] started identity=\(info.identityHash) destination=\(info.destinationHash)")
            logger.info("Python backend started — identity=\(info.identityHash, privacy: .public) destination=\(info.destinationHash, privacy: .public)")
        } catch {
            DiagLog.log("[RNS] start FAILED: \(error)")
            logger.error("Python backend start failed: \(error.localizedDescription, privacy: .public)")
            self.backend = nil
            throw error
        }

        await applyIncomingMessageSizeLimitFromSettings()

        #if COLUMBA_RUNTIME_PYTHON
        if propagationManager?.selectedNodeHash != nil {
            let reapplied = await propagationManager?.reapplySelectedNodeToPythonBackend() ?? false
            DiagLog.log("[RNS] reapplied persisted propagation node to Python: \(reapplied)")
            try await PropagationNodeRestoreReadiness.validate(
                reapplied: reapplied,
                rollback: { [weak self] in
                    await backend.stop()
                    self?.backend = nil
                }
            )
        }
        #endif

        // Outbound LXMF now goes directly through `backend.lxmf.sendLxmfMessage`
        // (MessagingViewModel + RnsLxmf) with TYPED fields, so the old Compat
        // router sendHook — which forwarded content only and dropped every field —
        // is retired. The Compat LXMRouter remains solely as the inbound delegate
        // holder (IncomingMessageHandler, wired in ColumbaApp); fully retiring it
        // would require the LXMRouterDelegate protocol to drop its router param
        // (a separate, lower-value cleanup).

        // Event consumption intentionally starts only after ColumbaApp installs
        // IncomingMessageHandler as the Compat router delegate. Backend events queue
        // safely until startPythonEventDrain() is called; starting here would race
        // cold-launch inbound side-channel processing against handler creation.

        // Seed Compat TCPInterface stubs for each enabled InterfaceEntity so
        // the InterfaceManagement UI has something to render against. Their
        // state starts `.connecting`; the periodic status poll below flips
        // each one to `.connected` / `.disconnected` based on what Python's
        // RNS.Transport reports.
        for entity in interfaces where entity.type == .tcpClient || entity.type == .tcpServer {
            if tcpInterfaces[entity.id] == nil {
                let host: String
                let port: UInt16
                switch entity.config {
                case .tcpClient(let cfg): host = cfg.targetHost; port = cfg.targetPort
                case .tcpServer(let cfg): host = cfg.listenIp; port = cfg.listenPort
                default: host = ""; port = 0
                }
                let config = InterfaceConfig(
                    id: entity.id,
                    name: entity.name,
                    type: entity.type == .tcpClient ? .tcp : .tcp,
                    enabled: entity.enabled,
                    mode: .full,
                    host: host,
                    port: port
                )
                if let iface = try? TCPInterface(config: config) {
                    iface.state = .connecting
                    tcpInterfaces[entity.id] = iface
                }
            }
        }

        // Seed the live-interface set the status poll matches against. Kept
        // current by applyInterfaceChanges() on every hot-add / hot-remove —
        // the poll reads this each tick (NOT a value captured here) so a
        // mid-session interface change is reflected without a relaunch.
        self.pythonInterfaceEntities = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.id, $0) })

        // Periodic status poll: mirror Python's view of interface state into
        // the Compat TCPInterface stubs so the existing NetworkStatusView /
        // InterfaceManagementScreen show online / offline accurately.
        pythonStatusPollTask?.cancel()
        pythonStatusPollTask = Task { [weak self, backend] in
            var tick = 0
            DiagLog.log("[RNS-POLL] task started")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                tick += 1
                guard let snapshot = await backend.statusSnapshot() else {
                    if tick % 5 == 0 { DiagLog.log("[RNS-POLL] tick=\(tick) snapshot=nil") }
                    continue
                }
                guard let self else { return }
                let entityById = await MainActor.run { self.pythonInterfaceEntities }
                await self.applyPythonInterfaceStatus(snapshot: snapshot, entityById: entityById)
            }
            DiagLog.log("[RNS-POLL] task exiting (cancelled)")
        }

        #if DEBUG
        // Test-only deep-link observers (the `lxma://test-*` surface used by the
        // interop / smoke harnesses). The matching `onOpenURL` trigger in
        // ColumbaApp is itself `#if DEBUG`, so nothing posts these notifications in
        // release — gate the registrations too so they don't compile into release
        // builds (no inert listeners, smaller binary, no latent footgun if some
        // other code ever posts a `ColumbaTest*` name).

        // Listen for test-send deep links (lxma://test-send?to=HEX&content=…
        // [&method=…][&image_hex=…&image_format=…][&file_hex=…&file_name=…]).
        // Drives the full typed-LXMF send path the interop harness uses to
        // exercise image / file attachments end-to-end against a Sideband
        // peer (see Tests/interop/).
        addPythonObserver("ColumbaTestSend") { [weak self] note in
            guard let self else { return }
            guard let to = note.userInfo?["to"] as? String,
                  let content = note.userInfo?["content"] as? String else { return }
            let method = (note.userInfo?["method"] as? String) ?? ""
            let imageHex = (note.userInfo?["image_hex"] as? String) ?? ""
            let imageFormat = (note.userInfo?["image_format"] as? String) ?? ""
            let fileHex = (note.userInfo?["file_hex"] as? String) ?? ""
            let fileName = (note.userInfo?["file_name"] as? String) ?? ""
            // Resolve delivery method. `direct`/`propagated` ride a Link or
            // a propagation node, respectively; everything else (including
            // empty) goes opportunistic — matches LXDeliveryMethod's three
            // wire-method choices.
            let deliveryMethod: LXDeliveryMethod
            switch method.lowercased() {
            case "direct": deliveryMethod = .direct
            case "propagated": deliveryMethod = .propagated
            default: deliveryMethod = .opportunistic
            }
            // Hex → Data for the optional attachment payloads. Bad hex
            // silently drops the field so a typo in the URL surfaces as a
            // missing field in the inbound tap (loud) rather than a crash.
            let imageData: Data? = (!imageHex.isEmpty && !imageFormat.isEmpty)
                ? (try? imageHex.hexToData()) : nil
            let fileAttachments: [RnsFileAttachment]?
            if !fileHex.isEmpty && !fileName.isEmpty, let data = try? fileHex.hexToData() {
                fileAttachments = [RnsFileAttachment(name: fileName, data: data)]
            } else {
                fileAttachments = nil
            }
            Task { @MainActor in
                guard let backend = self.backend else {
                    DiagLog.log("[TEST-SEND] no backend")
                    return
                }
                do {
                    let outcome = try await backend.lxmf.sendLxmfMessage(
                        destHashHex: to,
                        content: content,
                        method: deliveryMethod,
                        imageData: imageData,
                        imageFormat: imageFormat.isEmpty ? nil : imageFormat,
                        fileAttachments: fileAttachments,
                        audioAttachment: nil,
                        iconAppearance: nil,
                        replyToMessageHashHex: nil,
                        replyQuotedContent: nil,
                        extraFields: nil
                    )
                    DiagLog.log("[TEST-SEND] outcome=\(outcome) method=\(deliveryMethod)")
                } catch {
                    DiagLog.log("[TEST-SEND] error=\(error)")
                }
            }
        }

        // Listen for test-telemetry deep links — the Tests/interop/ harness
        // uses these to pin `RnsTelemetry.sendLocationTelemetry` /
        // `sendTelemetryCease` on the active backend without driving the
        // CLLocationManager / GPS permission flow that the production
        // LocationSharingManager runs through.
        addPythonObserver("ColumbaTestTelemetry") { [weak self] note in
            guard let self else { return }
            guard let to = note.userInfo?["to"] as? String else { return }
            let packedHex = (note.userInfo?["packed_hex"] as? String) ?? ""
            let metaHex = (note.userInfo?["meta_hex"] as? String) ?? ""
            let cease = (note.userInfo?["cease"] as? Bool) ?? false
            Task { @MainActor in
                guard let backend = self.backend else {
                    DiagLog.log("[TEST-TELEMETRY] no backend")
                    return
                }
                do {
                    if cease {
                        // Same Android-shaped payload the UI path sends:
                        // zeroed FIELD_TELEMETRY + msgpack {"cease":true}.
                        let (packed, meta) = CeaseTelemetry.payload()
                        let outcome = try await backend.telemetry.sendLocationTelemetry(
                            destHashHex: to, packed: packed, customMeta: meta
                        )
                        DiagLog.log("[TEST-TELEMETRY] cease outcome=\(outcome)")
                    } else {
                        guard let packed = try? packedHex.hexToData(), !packed.isEmpty else {
                            DiagLog.log("[TEST-TELEMETRY] packed_hex missing or invalid")
                            return
                        }
                        let meta = (try? metaHex.hexToData()).flatMap { $0.isEmpty ? nil : $0 }
                        let outcome = try await backend.telemetry.sendLocationTelemetry(
                            destHashHex: to, packed: packed, customMeta: meta
                        )
                        DiagLog.log("[TEST-TELEMETRY] send outcome=\(outcome)")
                    }
                } catch {
                    DiagLog.log("[TEST-TELEMETRY] error=\(error)")
                }
            }
        }

        // Listen for test-restart deep link (lxma://test-restart) so
        // smoke tests can exercise the Apply & Restart path without UI.
        addPythonObserver("ColumbaTestRestart") { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                DiagLog.log("[TEST-RESTART] invoking restartPythonBackend")
                await self.restartPythonBackend()
                DiagLog.log("[TEST-RESTART] done")
            }
        }

        // Phase 4 smoke test: direct CB manager state probe. Bypasses the
        // Python driver so we can isolate Swift-side CB readiness from
        // Python wiring during early-bring-up debugging.
        addPythonObserver("ColumbaTestBLEStatus") { _ in
            #if canImport(CoreBluetooth)
            let bridge = SwiftBLEBridge.shared
            let isStarted = bridge.isStarted
            let connected = bridge.getConnectedPeers()
            DiagLog.log("[TEST-BLE-STATUS] started=\(isStarted) connected_peers=\(connected.count)")
            #else
            DiagLog.log("[TEST-BLE-STATUS] CoreBluetooth unavailable")
            #endif
        }

        #if COLUMBA_RUNTIME_PYTHON
        // Diagnose IOSBLEInterface load: exec the file in the same fresh
        // namespace RNS uses, surface any exception to DiagLog. Helps when
        // panic_on_interface_error=no silently swallows external-iface
        // load errors so the row shows "disconnected" with no signal.
        addPythonObserver("ColumbaTestBLEDiagnose") { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
                    DiagLog.log("[TEST-BLE-DIAG] no backend")
                    return
                }
                let result = await backend.pythonBridge.callModuleFunctionReturningString(
                    name: "diagnose_ios_ble_interface"
                ) ?? "(call returned nil)"
                // Multi-line tracebacks would get truncated by NSLog
                // formatting if logged as a single line; split and log
                // each line for readability.
                for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
                    DiagLog.log("[TEST-BLE-DIAG] \(line)")
                }
            }
        }

        // Dump path-table entries so we can see what the Node Details
        // "Interface Heard" card would render without taking a screenshot.
        addPythonObserver("ColumbaTestPathTable") { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
                    DiagLog.log("[TEST-PATH-TABLE] no backend")
                    return
                }
                let result = await backend.pythonBridge.callModuleFunctionReturningString(
                    name: "diagnose_path_table"
                ) ?? "(call returned nil)"
                for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
                    DiagLog.log("[TEST-PATH-TABLE] \(line)")
                }
            }
        }

        // Diagnose AutoInterface peer discovery: introspect the live
        // AutoInterface Python object so we can see whether multicast
        // join succeeded, what interfaces are bound, peer count, etc.
        addPythonObserver("ColumbaTestAutoDiagnose") { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
                    DiagLog.log("[TEST-AUTO-DIAG] no backend")
                    return
                }
                let result = await backend.pythonBridge.callModuleFunctionReturningString(
                    name: "diagnose_auto_interface"
                ) ?? "(call returned nil)"
                for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
                    DiagLog.log("[TEST-AUTO-DIAG] \(line)")
                }
            }
        }
        #endif

        // Phase 6 smoke test: dump current connection details (Android parity).
        addPythonObserver("ColumbaTestBLEPeerList") { _ in
            #if canImport(CoreBluetooth)
            let details = SwiftBLEBridge.shared.getConnectionDetails()
            DiagLog.log("[TEST-BLE-PEER-LIST] count=\(details.count)")
            for d in details {
                let idPrefix = d.identityHashHex.map { String($0.prefix(8)) } ?? "<no-id>"
                DiagLog.log("[TEST-BLE-PEER-LIST]   addr=\(d.address.prefix(8)) role=\(d.role.rawValue) mtu=\(d.mtu) id=\(idPrefix) rssi=\(d.rssi.map(String.init) ?? "?")")
            }
            #else
            DiagLog.log("[TEST-BLE-PEER-LIST] CoreBluetooth unavailable")
            #endif
        }

        // Phase 4 smoke test: direct CB scan toggle. Drives SwiftBLEBridge
        // without going through Python, so we can validate scan start/stop
        // works before plugging in the BLEDriverInterface contract.
        addPythonObserver("ColumbaTestBLEScan") { note in
            #if canImport(CoreBluetooth)
            let action = (note.userInfo?["action"] as? String) ?? "start"
            let bridge = SwiftBLEBridge.shared
            // Lazy-start the bridge so the CB managers exist when we call.
            if !bridge.isStarted {
                bridge.start(
                    serviceUuid: BleConstants.serviceUuid,
                    rxCharUuid: BleConstants.rxCharUuid,
                    txCharUuid: BleConstants.txCharUuid,
                    identityCharUuid: BleConstants.identityCharUuid
                )
            }
            if action == "stop" {
                bridge.stopScanning()
                DiagLog.log("[TEST-BLE-SCAN] stopScanning called")
            } else {
                bridge.startScanning()
                DiagLog.log("[TEST-BLE-SCAN] startScanning called")
            }
            #else
            DiagLog.log("[TEST-BLE-SCAN] CoreBluetooth unavailable")
            #endif
        }

        // Phase 4 smoke test: direct CB advertise toggle.
        addPythonObserver("ColumbaTestBLEAdvertise") { note in
            #if canImport(CoreBluetooth)
            let action = (note.userInfo?["action"] as? String) ?? "start"
            let name = (note.userInfo?["name"] as? String) ?? ""
            let bridge = SwiftBLEBridge.shared
            if !bridge.isStarted {
                bridge.start(
                    serviceUuid: BleConstants.serviceUuid,
                    rxCharUuid: BleConstants.rxCharUuid,
                    txCharUuid: BleConstants.txCharUuid,
                    identityCharUuid: BleConstants.identityCharUuid
                )
            }
            if action == "stop" {
                bridge.stopAdvertising()
                DiagLog.log("[TEST-BLE-ADVERTISE] stopAdvertising called")
            } else {
                bridge.startAdvertising(deviceName: name.isEmpty ? nil : name)
                DiagLog.log("[TEST-BLE-ADVERTISE] startAdvertising name=\"\(name)\"")
            }
            #else
            DiagLog.log("[TEST-BLE-ADVERTISE] CoreBluetooth unavailable")
            #endif
        }

        #if COLUMBA_RUNTIME_PYTHON
        // Phase 2 smoke test: Swift→Python BLE callback round-trip.
        // Installs `_test_roundtrip` Python callback that returns
        // True iff its int arg is even, then invokes it through the
        // synchronous bool-return BLE callback path. PASS iff Swift
        // gets back the expected bool for both even and odd inputs.
        addPythonObserver("ColumbaTestBLECallback") { [weak self] note in
            guard let self else { return }
            let value = (note.userInfo?["value"] as? Int) ?? 4
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
                    DiagLog.log("[TEST-BLE-CB] FAIL: no backend")
                    return
                }
                let installed = await backend.installBLETestRoundtripCallback()
                guard installed else {
                    DiagLog.log("[TEST-BLE-CB] FAIL: callback install failed")
                    return
                }
                let evenResult = backend.invokeBLETestRoundtrip(value: value)
                let oddResult = backend.invokeBLETestRoundtrip(value: value + 1)
                let evenExpected = value % 2 == 0
                let oddExpected = (value + 1) % 2 == 0
                let pass = evenResult == evenExpected && oddResult == oddExpected
                DiagLog.log("[TEST-BLE-CB] value=\(value) even=\(evenResult) odd=\(oddResult) \(pass ? "PASS" : "FAIL")")
            }
        }
        #endif

        // lxma://test-answer — accept the currently-ringing call.
        addPythonObserver("ColumbaTestAnswer") { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                #if os(iOS)
                guard let callManager = self.callManager else {
                    DiagLog.log("[TEST-ANSWER] no callManager")
                    return
                }
                DiagLog.log("[TEST-ANSWER] calling answerCall()")
                callManager.answerCall()
                #endif
            }
        }

        // lxma://test-call?to=HEX[&profile=...] — exercise the full call
        // pipeline: CallManager.initiateCall → Telephone.call →
        // Compat.Link.sendBytes → PythonRNSBackend.linkSend.
        addPythonObserver("ColumbaTestCall") { [weak self] note in
            guard let self else { return }
            let to = (note.userInfo?["to"] as? String) ?? ""
            let profileRaw = (note.userInfo?["profile"] as? String) ?? ""
            Task { @MainActor in
                #if os(iOS)
                guard let callManager = self.callManager else {
                    DiagLog.log("[TEST-CALL] no callManager")
                    return
                }
                guard let destHash = try? to.hexToData() else {
                    DiagLog.log("[TEST-CALL] bad to= hex")
                    return
                }
                // Pick profile: default to qualityMedium if not specified or
                // unrecognized; parse rawValue if present.
                var profile: TelephonyProfile = .qualityMedium
                if !profileRaw.isEmpty, let parsed = TelephonyProfile.allCases.first(where: { "\($0)" == profileRaw }) {
                    profile = parsed
                }
                DiagLog.log("[TEST-CALL] initiating to=\(destHash.toHex().prefix(8)) profile=\(profile)")
                callManager.initiateCall(destinationHash: destHash, profile: profile, peerDisplayName: nil)
                #else
                DiagLog.log("[TEST-CALL] CallManager only available on iOS")
                #endif
            }
        }

        // lxma://test-link-open?to=HEX&aspect=lxst.telephony — exercise the
        // RNS.Link bridge by opening an outbound Link to a destination.
        // Logs the link_id + waits for link_state events to surface via
        // NotificationCenter. For commit-1 smoke testing.
        addPythonObserver("ColumbaTestLinkOpen") { [weak self] note in
            guard let self else { return }
            let to = (note.userInfo?["to"] as? String) ?? ""
            let aspect = (note.userInfo?["aspect"] as? String) ?? "lxst.telephony"
            Task { @MainActor in
                guard let backend = self.backend else {
                    DiagLog.log("[TEST-LINK] no backend")
                    return
                }
                do {
                    let res = try await backend.openLink(destHashHex: to, aspect: aspect, identityPublicKeyHex: nil)
                    DiagLog.log("[TEST-LINK] open ok=\(res.ok) linkId=\(res.linkId) reason=\(res.reason)")
                } catch {
                    DiagLog.log("[TEST-LINK] open error=\(error)")
                }
            }
        }

        // lxma://test-inbound?from=HEX&content=... — synthesize an inbound
        // event so the privacy filter (block_unknown_senders) can be
        // verified without needing a working peer.
        addPythonObserver("ColumbaTestInbound") { [weak self] note in
            guard let self else { return }
            let fromHex = (note.userInfo?["from"] as? String) ?? ""
            let content = (note.userInfo?["content"] as? String) ?? "synthetic"
            guard let from = Data(hexString: fromHex) else {
                DiagLog.log("[TEST-INBOUND] bad hex")
                return
            }
            let testHashInput = (fromHex + content + String(Date().timeIntervalSince1970))
                .data(using: .utf8) ?? Data()
            let testMessageHash = Data(SHA256.hash(data: testHashInput))
                .map { String(format: "%02x", $0) }.joined()
            Task { @MainActor in
                await self.persistInboundFromPython(
                    sourceHash: from,
                    messageHashHex: testMessageHash,
                    content: content,
                    title: "",
                    fields: nil,
                    method: .opportunistic,
                    timestamp: Date()
                )
            }
        }

        // lxma://test-message-status?from=HEX&message=HEX — query the same
        // canonical repository the UI reads. Metadata only; never logs content.
        addPythonObserver("ColumbaTestMessageStatus") { [weak self] note in
            guard let self else { return }
            let fromHex = (note.userInfo?["from"] as? String) ?? ""
            let messageHex = (note.userInfo?["message"] as? String) ?? ""
            Task { @MainActor in
                guard let repo = self.messageRepository,
                      let from = Data(hexString: fromHex),
                      let message = Data(hexString: messageHex) else {
                    DiagLog.log("[TEST-MESSAGE-STATUS] invalid-input-or-repository")
                    return
                }
                do {
                    let row = try await repo.getMessageRecord(id: message)
                    let conversation = try await repo.fetchConversation(from)
                    let records = try await repo.fetchMessageRecords(for: from)
                    let exactCount = records.filter { $0.messageId == message }.count
                    DiagLog.log(
                        "[TEST-MESSAGE-STATUS] row=\(row != nil) conversation=\(conversation != nil) "
                        + "conversationRows=\(records.count) exactRows=\(exactCount) "
                        + "previewEmpty=\(conversation?.lastMessagePreview.isEmpty ?? true)"
                    )
                } catch {
                    DiagLog.log("[TEST-MESSAGE-STATUS] query-failed=\(error.localizedDescription)")
                }
            }
        }

        // lxma://test-identity-switch — exercise the multi-identity swap
        // path: create a fresh identity in IdentityManager and call
        // AppServices.switchIdentity. Logs the destination hash before
        // and after so we can verify Python actually rebooted with the
        // new keys.
        addPythonObserver("ColumbaTestIdentitySwitch") { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let manager = IdentityManager()
                let before = self.backend?.localInfo?.destinationHash ?? "nil"
                DiagLog.log("[TEST-IDSWITCH] before destination=\(before)")
                do {
                    let created = try await manager.createIdentity(displayName: "SwitchTarget")
                    let (localId, identity) = try await manager.switchToIdentity(created.identityHash)
                    try await self.switchIdentity(
                        to: identity,
                        identityHash: localId.identityHash,
                        tcpServerAddress: ""
                    )
                    let after = self.backend?.localInfo?.destinationHash ?? "nil"
                    DiagLog.log("[TEST-IDSWITCH] after destination=\(after) (changed=\(before != after))")
                } catch {
                    DiagLog.log("[TEST-IDSWITCH] error=\(error)")
                }
            }
        }

        // lxma://test-prop-sync?node=HEX — set propagation node, kick a sync,
        // log the outcome.
        addPythonObserver("ColumbaTestPropSync") { [weak self] note in
            guard let self else { return }
            let node = (note.userInfo?["node"] as? String) ?? ""
            Task { @MainActor in
                // Model B: the LXMF router lives in the NE — `backend.propagationSync`
                // is a no-op proxy stub. Route through the propagation manager so the
                // PN crosses the App-Group seam and the NE runs the sync (this mirrors
                // the production Sync Now path).
                if BackendPreference.modelB {
                    guard let propManager = self.propagationManager else {
                        DiagLog.log("[TEST-PROP-SYNC] modelB: no propagation manager")
                        return
                    }
                    if !node.isEmpty, let hash = Data(hexString: node) {
                        await propManager.selectNode(hash: hash)
                    }
                    await propManager.syncNow()
                    DiagLog.log("[TEST-PROP-SYNC] modelB sync-now posted to NE, state=\(propManager.syncState.state)")
                    return
                }
                guard let backend = self.backend else {
                    DiagLog.log("[TEST-PROP-SYNC] no backend")
                    return
                }
                do {
                    _ = try await backend.setPropagationNode(destHashHex: node, stampCost: 0)
                    DiagLog.log("[TEST-PROP-SYNC] set node, starting sync")
                    let r = try await backend.propagationSync(timeout: 30.0)
                    DiagLog.log("[TEST-PROP-SYNC] result ok=\(r.ok) state=\(r.state.rawValue) received=\(r.receivedMessages) reason=\(r.reason)")
                } catch {
                    DiagLog.log("[TEST-PROP-SYNC] error=\(error)")
                }
            }
        }

        // lxma://test-announce?name=... — calls sendAllAnnounces with the
        // given display name (both the LXMF delivery + LXST telephony
        // destinations), logs the outcome.
        addPythonObserver("ColumbaTestAnnounce") { [weak self] note in
            guard let self else { return }
            let name = (note.userInfo?["name"] as? String) ?? ""
            Task { @MainActor in
                do {
                    try await self.sendAllAnnounces(displayName: name)
                    DiagLog.log("[TEST-ANNOUNCE] sendAllAnnounces returned OK")
                } catch {
                    DiagLog.log("[TEST-ANNOUNCE] sendAllAnnounces failed: \(error)")
                }
            }
        }

        // lxma://test-nomad-fetch?to=HEX&path=/page/index.mu — calls
        // bridge.fetchNomadNetPage and logs the response.
        addPythonObserver("ColumbaTestNomadFetch") { [weak self] note in
            guard let self else { return }
            guard let to = note.userInfo?["to"] as? String,
                  let path = note.userInfo?["path"] as? String else { return }
            Task { @MainActor in
                guard let backend = self.backend else {
                    DiagLog.log("[TEST-NOMAD] no backend")
                    return
                }
                do {
                    let res = try await backend.fetchNomadNetPage(destHashHex: to, path: path)
                    let preview = String(data: res.data.prefix(120), encoding: .utf8) ?? "(non-utf8 \(res.data.count) bytes)"
                    DiagLog.log("[TEST-NOMAD] result ok=\(res.ok) status=\(res.status.rawValue) bytes=\(res.data.count) preview=\(preview)")
                } catch {
                    DiagLog.log("[TEST-NOMAD] error=\(error)")
                }
            }
        }
        #endif // DEBUG — test-only deep-link observers
    }

    /// Begin consuming queued backend events only after the app has installed its
    /// IncomingMessageHandler. Idempotent across repeated scene initialization.
    func startPythonEventDrain() {
        guard pythonEventTask == nil, let backend else {
            DiagLog.log("[RNS] event drain start skipped active=\(pythonEventTask != nil) backend=\(backend != nil)")
            return
        }
        DiagLog.log("[RNS] event drain started after incoming handler installation")
        pythonEventTask = Task { [weak self, backend] in
            for await event in backend.events {
                guard let self else { break }
                guard await self.pythonHostEventProcessingGate.beginNormal() else { break }
                await self.handlePythonEvent(event)
                await self.pythonHostEventProcessingGate.endNormal()
            }
        }
    }

    @MainActor
    public func applyIncomingMessageSizeLimitFromSettings() async {
        #if COLUMBA_RUNTIME_PYTHON
        let limitKB = await settingsRepository.getIncomingMessageSizeLimitKB()
        guard let pythonBackend = backend as? PythonRNSBackend else {
            DiagLog.log("[LXMF_CAP] skipping inbound cap apply: shipping Python backend unavailable")
            return
        }
        do {
            let applied = try await pythonBackend.setIncomingMessageSizeLimitKB(limitKB)
            DiagLog.log("[LXMF_CAP] applied inbound cap=\(limitKB)KB applied=\(applied)")
        } catch {
            DiagLog.log("[LXMF_CAP] failed to apply inbound cap=\(limitKB)KB error=\(error.localizedDescription)")
        }
        #endif
    }

    /// Look up the matching Python interface for each user `InterfaceEntity`
    /// and update the Compat TCPInterface stub's `state` to reflect the
    /// `online` flag RNS.Transport reports.
    private func applyPythonInterfaceStatus(
        snapshot: StatusSnapshot,
        entityById: [String: InterfaceEntity]
    ) async {
        // Log every interface Python reports so we can see AutoInterface /
        // RNode / etc. that don't have Compat stubs yet. One-shot per
        // section_name change.
        let snapshotKey = snapshot.interfaces.map { "\($0.sectionName):\($0.online ? 1 : 0)" }.joined(separator: ",")
        if snapshotKey != lastInterfaceSnapshotKey {
            DiagLog.log("[RNS] interfaces=\(snapshotKey)")
            lastInterfaceSnapshotKey = snapshotKey
        }
        // The config section name PythonConfigWriter wrote is the matching
        // key — it's stable across the bridge and unique per entity.
        var byEntity: [String: StatusSnapshot.InterfaceStatus] = [:]
        var matchedSectionNames: Set<String> = []
        for status in snapshot.interfaces {
            for (entityId, entity) in entityById {
                let expected = expectedSectionName(for: entity)
                if status.sectionName == expected {
                    byEntity[entityId] = status
                    matchedSectionNames.insert(status.sectionName)
                }
            }
        }
        // Auxiliary: any Python interface that didn't match an entity is a
        // dynamically-spawned peer (AutoInterfacePeer / BLEPeer / etc.).
        // Push these into the Transport so NetworkStatusView can render them.
        // Python AutoInterfacePeer's `name` is the class name; the `name`
        // field of the status dict is `str(iface)` which gives us the
        // friendly "AutoInterfacePeer[en0/fe80::xxxx]" — peel out the
        // peer address from there for the row subtitle.
        var auxiliary: [InterfaceSnapshot] = []
        for status in snapshot.interfaces where !matchedSectionNames.contains(status.sectionName) {
            // Skip user-defined sections we just couldn't match for some
            // reason (rename race, etc.) — only emit synthetic rows for
            // peer-style names.
            let isAutoPeer = status.name.hasPrefix("AutoInterfacePeer")
            let isBlePeer = status.name.hasPrefix("BLEPeerInterface") || status.name.hasPrefix("BLEPeer")
            guard isAutoPeer || isBlePeer else { continue }
            let typeLabel = isAutoPeer ? "AutoInterfacePeer" : "BLEPeer"
            // Peel out the bracketed addr — "AutoInterfacePeer[en0/fe80::1]"
            // gives "en0/fe80::1".
            let peerAddress: String? = {
                guard let open = status.name.firstIndex(of: "["),
                      let close = status.name.lastIndex(of: "]"),
                      open < close else { return nil }
                return String(status.name[status.name.index(after: open)..<close])
            }()
            auxiliary.append(InterfaceSnapshot(
                id: "py-aux:\(status.sectionName.isEmpty ? status.name : status.sectionName)",
                name: status.name,
                online: status.online,
                typeLabel: typeLabel,
                type: isAutoPeer ? .autoInterface : .ble,
                state: status.online ? .connected : .disconnected,
                isAutoInterfacePeer: isAutoPeer,
                isBLEPeerInterface: isBlePeer,
                peerAddress: peerAddress,
                lastErrorDescription: nil
            ))
        }
        if let transport = transport {
            transport.setPythonAuxiliarySnapshots(auxiliary)
        }
        // One-shot log of auxiliary count changes so we can see whether
        // LAN / BLE peer discovery is actually firing.
        let auxKey = auxiliary.map(\.id).sorted().joined(separator: ",")
        if auxKey != lastAuxiliaryKey {
            DiagLog.log("[RNS] auxiliary interfaces (\(auxiliary.count)): \(auxKey)")
            lastAuxiliaryKey = auxKey
        }
        for (entityId, status) in byEntity {
            let newState: InterfaceState = status.online ? .connected : .disconnected
            // TCP interfaces keyed by entity ID.
            if let iface = tcpInterfaces[entityId] {
                if iface.state != newState {
                    DiagLog.log("[RNS] iface \(status.sectionName) -> \(newState) (rx=\(status.rxBytes) tx=\(status.txBytes))")
                    iface.state = newState
                    iface.online = status.online
                }
                continue
            }
            // Auto + BLE interfaces are singletons on AppServices, keyed by
            // entity type rather than ID. Match the corresponding entity and
            // mirror Python's reported state onto the Swift stub so the UI
            // can render an accurate "connected/disconnected" badge.
            guard let entity = entityById[entityId] else { continue }
            switch entity.config {
            case .autoInterface:
                if let auto = self.autoInterface, auto.state != newState {
                    DiagLog.log("[RNS] iface \(status.sectionName) -> \(newState) (Auto, rx=\(status.rxBytes) tx=\(status.txBytes))")
                    auto.state = newState
                    auto.online = status.online
                }
            case .ble:
                if let ble = self.bleInterface, ble.state != newState {
                    DiagLog.log("[RNS] iface \(status.sectionName) -> \(newState) (BLE, rx=\(status.rxBytes) tx=\(status.txBytes))")
                    ble.state = newState
                    ble.online = status.online
                }
            case .rnode:
                // RNode now runs through the Model B seam on the Swift backend
                // (UI state applied via applyRNodeLinkState). The Python backend
                // no longer has an RNode interface, so this status mirror is inert
                // there — kept for switch exhaustiveness + parity with Auto/BLE.
                if let rnode = self.rnodeInterface, rnode.state != newState {
                    DiagLog.log("[RNS] iface \(status.sectionName) -> \(newState) (RNode, rx=\(status.rxBytes) tx=\(status.txBytes))")
                    rnode.state = newState
                    rnode.online = status.online
                }
            default:
                break
            }
        }
    }

    /// Stop the running Python RNS stack, regenerate the RNS config file
    /// from `InterfaceRepository.getEnabledInterfaces()`, and start a fresh
    /// instance. Called from the InterfaceManagementScreen's "Apply &
    /// Restart" button after the user adds, edits, toggles, or removes an
    /// interface. RNS has no hot-reload — the only way to pick up a new
    /// `[interfaces]` section is a full Reticulum re-init.
    ///
    /// Causes a ~1-2s connectivity outage. Caller should reflect the
    /// transition in the UI (the Apply button already shows a
    /// ProgressView while `isApplyingChanges` is set).
    public func restartPythonBackend() async {
        guard let identity = pythonStartIdentity else {
            DiagLog.log("[RNS] restart skipped — backend was never started")
            return
        }
        // Rewrite the RNS config on disk so the new interface set is
        // captured. The actual Python-side restart is DELIBERATELY skipped
        // — in-place restart of the embedded interpreter is flaky on iOS
        // (Reticulum is a class-level singleton, AutoInterface holds
        // multicast socket threads that don't tear down deterministically,
        // and the embedded Python aborts ~130ms into the second
        // `Reticulum.__init__` when the previous instance's threads still
        // hold the multicast bind). RNS has no hot-reload of [interfaces]
        // anyway, so the right model is: write the config, tell the user
        // to relaunch Columba. The full app launch on the next start gets
        // a clean Python + clean RNS singleton.
        _ = identity // pythonStartIdentity presence is the only precondition
        let fresh = InterfaceRepository().getEnabledInterfaces()
        writePythonConfig(interfaces: fresh)
        DiagLog.log("[RNS] restartPythonBackend: config written (\(fresh.count) interfaces); awaiting next app launch to apply")
        // Notify the UI so it can show a "relaunch Columba" prompt.
        NotificationCenter.default.post(
            name: Notification.Name("ColumbaRelaunchRequired"),
            object: nil
        )
    }

    /// Force the Python RNS stack to flush its path table + known destinations
    /// to disk. RNS only persists on a 12h timer / clean exit, and iOS suspends
    /// the app without a clean exit — so we call this when the app backgrounds,
    /// otherwise RNS's `destination_table` / `known_destinations` are rarely
    /// written and a cold start can't recall previously-heard peers.
    ///
    /// Wrapped in a UIKit background task so the file writes have a chance to
    /// finish before iOS suspends us.
    @MainActor
    public func persistRNSStateOnBackground() {
        guard let backend = backend else { return }
        #if canImport(UIKit)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "rns-persist") {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }
        Task {
            _ = await backend.persist()
            await MainActor.run {
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
            }
        }
        #else
        Task { _ = await backend.persist() }
        #endif
    }

    /// Directory holding the running Python instance's RNS config, derived from
    /// the identity the backend was started with. Returns nil if the backend
    /// was never started (no cached identity). Creates the directory if needed.
    private func pythonConfigDirURL() -> URL? {
        guard let identity = pythonStartIdentity else { return nil }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pyDir = appSupport.appendingPathComponent("Columba/python-\(identity.hexHash)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pyDir, withIntermediateDirectories: true)
        return pyDir
    }

    /// Write the RNS config file from the given interface set. This is the
    /// durability backstop: it keeps `<configDir>/config` authoritative so a
    /// cold launch (or the transport-mode full restart) reflects the current
    /// interfaces. It is NOT how live changes take effect — `add_interface` /
    /// `remove_interface` reads this file but the running stack is reconfigured
    /// by `applyInterfaceChanges()`.
    @discardableResult
    private func writePythonConfig(interfaces: [InterfaceEntity]) -> Bool {
        guard let pyDir = pythonConfigDirURL() else {
            DiagLog.log("[RNS] writePythonConfig skipped — no start identity")
            return false
        }
        let transportEnabled = SharedDefaults.suite.bool(forKey: "transport_enabled")
        let configText = PythonConfigWriter.write(interfaces: interfaces, enableTransport: transportEnabled)
        let configFile = pyDir.appendingPathComponent("config")
        do {
            try configText.write(to: configFile, atomically: true, encoding: .utf8)
            DiagLog.log("[RNS] wrote config (\(configText.count) bytes, \(interfaces.count) interfaces)")
            return true
        } catch {
            DiagLog.log("[RNS] config write FAILED: \(error)")
            return false
        }
    }

    /// Apply pending interface changes to the *running* RNS stack with no
    /// restart and no app relaunch.
    ///
    /// RNS attaches/detaches interfaces on a live `Transport` (the same
    /// primitive its 1.x interface-discovery autoconnect uses). We diff the
    /// just-saved enabled set against what's currently live
    /// (`pythonInterfaceEntities`) and:
    ///   1. rewrite the config file (durability for the next cold launch),
    ///   2. hot-remove dropped interfaces (and the old form of edited ones),
    ///   3. hot-add new interfaces (and the new form of edited ones),
    ///   4. seed/tear down the Swift-side status mirrors so the UI badges
    ///      track reality immediately,
    ///   5. update `pythonInterfaceEntities` so the status poll matches the
    ///      new set.
    ///
    /// Edited interfaces are handled as remove-then-add: `add_interface` reads
    /// the freshly-written config section, so changed host/port/etc. take
    /// effect. Caveat: removing an AutoInterface is not a clean teardown
    /// upstream (its `detach()` leaves multicast sockets bound until process
    /// exit), so re-adding the same AutoInterface mid-session may collide —
    /// TCP is unaffected.
    @MainActor
    public func applyInterfaceChanges() async {
        await withLifecycleOperation {
            await applyInterfaceChangesUnlocked()
        }
    }

    private func applyInterfaceChangesUnlocked() async {
        // Model B: the NE owns the RNS node + all interfaces; the app's `backend` here is
        // the thin `ProxyRnsBackend`, whose `addInterface` throws `unsupportedInProxy`. The
        // python-shaped hot-add/-remove path below is therefore both wrong (it would error
        // on every relay) AND unnecessary — `InterfaceRepository.saveInterfaces()` already
        // wrote the shared `interfacesKey` and posted `configChanged`, which the NE observes
        // (`startTCPRelayConfigObserver` → `reconcileTCPRelays`) to live-reconcile its
        // `ne-tcp-relay-*` interfaces. So a relay add/edit/remove takes effect with NO VPN
        // restart. Nothing more to do app-side; bail before the python path.
        if BackendPreference.modelB {
            DiagLog.log("[RNS-HOT] modelB: interface change handed to NE via configChanged (no app-side hot-add)")
            return
        }

        let fresh = InterfaceRepository().getEnabledInterfaces()
        let freshById = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })

        // 1. Durability — always persist, even if there's no live backend.
        writePythonConfig(interfaces: fresh)

        guard let backend = backend else {
            DiagLog.log("[RNS-HOT] no running backend — config written, applies on next launch")
            pythonInterfaceEntities = freshById
            return
        }

        let live = pythonInterfaceEntities
        let removed = live.values.filter { freshById[$0.id] == nil }
        let added = fresh.filter { live[$0.id] == nil }
        let changed = fresh.filter { e in
            guard let old = live[e.id] else { return false }
            return old != e
        }

        DiagLog.log("[RNS-HOT] applyInterfaceChanges: +\(added.count) -\(removed.count) ~\(changed.count)")

        // 2. Remove dropped interfaces, and the OLD form of edited ones.
        for entity in removed {
            await hotRemoveInterface(entity, backend: backend)
        }
        for entity in changed {
            if let old = live[entity.id] {
                await hotRemoveInterface(old, backend: backend)
            }
        }

        // 3. Add new interfaces, and the NEW form of edited ones.
        for entity in added + changed {
            await hotAddInterface(entity, backend: backend)
        }

        #if COLUMBA_RUNTIME_MODEL_B
        // 4. Newly hot-added interfaces are created in normal (local-socket) mode.
        // The tunnel-mode coordinator (`applyTunnelModeToInterfaces`) only fires on
        // VPN *status* changes, not interface changes — so if background transport
        // is already up, an interface added afterward (e.g. switching Auto -> a TCP
        // relay after enabling background transport) would never enter tunnel mode,
        // and with the packet tunnel active its own socket is black-holed
        // (connected, rx=0 tx=0). Re-assert tunnel mode so anything added while the
        // tunnel is up is bridged through the extension.
        await reapplyTunnelModeIfActive()
        #endif

        // 5. Keep the status-poll's matching set in sync with what's live.
        pythonInterfaceEntities = freshById
    }

    /// Hot-add one interface to the running Python stack and seed its Swift
    /// status mirror. Assumes the config file already contains the section
    /// (callers run `writePythonConfig` first).
    @MainActor
    private func hotAddInterface(_ entity: InterfaceEntity, backend: any RnsBackend) async {
        let section = PythonConfigWriter.sectionName(for: entity)
        do {
            let r = try await backend.addInterface(name: section)
            DiagLog.log("[RNS-HOT] add \(section): ok=\(r.ok) reason=\(r.reason)")
        } catch {
            DiagLog.log("[RNS-HOT] add \(section) error: \(error)")
        }
        await seedSwiftStub(for: entity)
    }

    /// Hot-remove one interface from the running Python stack and tear down its
    /// Swift status mirror.
    @MainActor
    private func hotRemoveInterface(_ entity: InterfaceEntity, backend: any RnsBackend) async {
        let section = PythonConfigWriter.sectionName(for: entity)
        do {
            let r = try await backend.removeInterface(name: section)
            DiagLog.log("[RNS-HOT] remove \(section): ok=\(r.ok) reason=\(r.reason)")
        } catch {
            DiagLog.log("[RNS-HOT] remove \(section) error: \(error)")
        }
        await teardownSwiftStub(for: entity)
    }

    /// Create the Swift-side status mirror for a freshly hot-added interface so
    /// NetworkStatusView / Manage Interfaces / the Settings card can render it.
    /// TCP interfaces get a Compat stub (state starts `.connecting`; the status
    /// poll flips it based on Python's view). Auto/BLE/RNode reuse the existing
    /// start* singletons, matching what the launch path (ColumbaApp Step 7) does.
    @MainActor
    private func seedSwiftStub(for entity: InterfaceEntity) async {
        switch entity.config {
        case .tcpClient(let cfg):
            if tcpInterfaces[entity.id] == nil {
                let config = InterfaceConfig(
                    id: entity.id, name: entity.name, type: .tcp,
                    enabled: true, mode: .full, host: cfg.targetHost, port: cfg.targetPort
                )
                if let iface = try? TCPInterface(config: config) {
                    iface.state = .connecting
                    tcpInterfaces[entity.id] = iface
                }
            }
        case .tcpServer(let cfg):
            if tcpInterfaces[entity.id] == nil {
                let config = InterfaceConfig(
                    id: entity.id, name: entity.name, type: .tcp,
                    enabled: true, mode: .full, host: cfg.listenIp, port: cfg.listenPort
                )
                if let iface = try? TCPInterface(config: config) {
                    iface.state = .connecting
                    tcpInterfaces[entity.id] = iface
                }
            }
        case .autoInterface(let cfg):
            try? await startAutoInterfaceUnlocked(groupId: cfg.groupId ?? "reticulum")
        case .ble:
            #if canImport(CoreBluetooth)
            try? await startBLEInterfaceUnlocked()
            #endif
        case .rnode(let cfg):
            try? await startRNodeInterfaceUnlocked(config: cfg, name: entity.name)
        case .multipeer:
            break // Multipeer status mirror not wired for hot-add yet.
        }
    }

    /// Tear down the Swift-side status mirror for a hot-removed interface so the
    /// UI stops showing it as connected. This is what fixes the stale
    /// "Bluetooth connected" card after disabling BLE.
    @MainActor
    private func teardownSwiftStub(for entity: InterfaceEntity) async {
        switch entity.config {
        case .tcpClient, .tcpServer:
            if let iface = tcpInterfaces[entity.id] {
                await iface.disconnect()
                await transport?.removeInterface(id: entity.id)
                tcpInterfaces.removeValue(forKey: entity.id)
            }
        case .autoInterface:
            await stopAutoInterfaceUnlocked()
        case .ble:
            #if canImport(CoreBluetooth)
            await stopBLEInterfaceUnlocked()
            #endif
        case .rnode:
            await stopRNodeInterfaceUnlocked()
        case .multipeer:
            break
        }
    }

    /// Re-instantiate the Swift-side interface singletons / stubs for each
    /// enabled `InterfaceEntity` after a Python restart. Idempotent (each
    /// start*Interface method early-exits if already up).
    private func respawnSwiftInterfaceStubs(enabled: [InterfaceEntity]) async {
        for entity in enabled {
            switch entity.config {
            case .tcpClient(let config):
                let entityId = entity.id
                do {
                    try await connectTCPInterfaceUnlocked(entityId: entityId, host: config.targetHost, port: config.targetPort)
                    DiagLog.log("[RESPAWN] TCP \(entityId) connected")
                } catch {
                    DiagLog.log("[RESPAWN] TCP \(entityId) failed: \(error)")
                }
            case .autoInterface(let config):
                let groupId = config.groupId ?? "reticulum"
                do {
                    try await startAutoInterfaceUnlocked(groupId: groupId)
                    DiagLog.log("[RESPAWN] AutoInterface started groupId=\(groupId)")
                } catch {
                    DiagLog.log("[RESPAWN] AutoInterface failed: \(error)")
                }
            case .ble:
                #if canImport(CoreBluetooth)
                do {
                    try await startBLEInterfaceUnlocked()
                    DiagLog.log("[RESPAWN] BLEInterface started")
                } catch {
                    DiagLog.log("[RESPAWN] BLEInterface failed: \(error)")
                }
                #endif
            case .tcpServer, .rnode, .multipeer:
                // tcpServer + RNode + Multipeer aren't auto-started on
                // restart yet (no parity with ColumbaApp.swift initial
                // startup); add when those flows are formalized.
                break
            }
        }
    }

    /// Recompute the config-section name PythonConfigWriter would have
    /// written for an entity, so we can match Python interface objects back
    /// to entities by section_name.
    private func expectedSectionName(for entity: InterfaceEntity) -> String {
        // Delegate to the single source of truth used by the config writer and
        // the hot-add / hot-remove path, so status matching can never drift
        // from the section names actually written to the RNS config.
        PythonConfigWriter.sectionName(for: entity)
    }

    /// Save a Python-delivered inbound LXMF message to the repository and
    /// notify the chats UI. Mirrors the work IncomingMessageHandler does
    /// on receipt but is invoked directly because Python is what surfaced
    /// the message — there's no Swift LXMRouter callback to hook.
    ///
    /// Honors the `block_unknown_senders` privacy toggle (Settings →
    /// Privacy): when enabled, drops the inbound message unless the
    /// sender is a known + favorited contact. This must live here
    /// because we bypass IncomingMessageHandler — Python's delivery
    /// callback feeds straight into this method.
    /// Persist an inbound message + return it (with its fields) so the caller can
    /// run side-channel handling (reactions/replies/telemetry/icon/cease) through
    /// IncomingMessageHandler. Returns nil if blocked or persistence failed.
    @discardableResult
    private func persistInboundFromPython(sourceHash: Data, messageHashHex: String, content: String, title: String, fields: [UInt8: Any]?, method: LXDeliveryMethod?, rssi: Double? = nil, snr: Double? = nil, timestamp: Date) async -> LXMessage? {
        // Route Python-path inbound persistence through the GRDB canonical
        // store (the same one the UI reads and the Swift/NE path writes), via
        // the shared MessageRepository's RNSAPI-typed methods — NOT the
        // RNSAPI Compat `database`. (The Swift backend already persists its own
        // inbound to GRDB through its LXMRouter, so this AppServices write is
        // only for the Python backend path.)
        guard let repo = self.messageRepository else {
            DiagLog.log("[RNS] persistInbound: no messageRepository")
            return nil
        }
        let sourceHashHex = sourceHash.map { String(format: "%02x", $0) }.joined()

        // Privacy: block_unknown_senders drops messages from anyone the
        // user hasn't explicitly favorited (matches the existing
        // IncomingMessageHandler check — favorite is the "this is a
        // real contact, not a random announce hop" signal).
        if UserDefaults.standard.bool(forKey: "block_unknown_senders") {
            let isKnownContact: Bool
            do {
                let conversation = try await repo.fetchConversation(sourceHash)
                isKnownContact = (conversation?.isFavorite ?? 0) != 0
            } catch {
                // Fail open: surface the message if the DB check itself
                // fails (better than silently dropping mail).
                isKnownContact = true
            }
            if !isKnownContact {
                DiagLog.log("[RNS] persistInbound BLOCKED source=\(sourceHashHex.prefix(8)) (block_unknown_senders enabled)")
                return nil
            }
        }

        let displayName = "Peer \(sourceHashHex.prefix(8))"

        do {
            // Reactions and replies target the exact 32-byte LXMF wire hash.
            // Preserve an abnormal delivered message that lacks that hash under a
            // 33-byte, namespaced local persistence ID instead of dropping it.
            // UI adapters expose only 32-byte IDs as network-addressable hashes,
            // so the local ID can never leak into a reaction or reply frame.
            let parsedHash = Data(hexString: messageHashHex)
            let messageHash: Data
            if let parsedHash, parsedHash.count == 32 {
                messageHash = parsedHash
            } else {
                var seed = Data("columba-local-inbound-v1".utf8)
                seed.append(sourceHash)
                var timestampBits = timestamp.timeIntervalSince1970.bitPattern.bigEndian
                withUnsafeBytes(of: &timestampBits) { seed.append(contentsOf: $0) }
                seed.append(Data(title.utf8))
                seed.append(0)
                seed.append(Data(content.utf8))
                if let fields {
                    seed.append(LxmfFieldCodec.pack(fields))
                }
                messageHash = Data([0x00]) + Data(SHA256.hash(data: seed))
                DiagLog.log("[RNS] persistInbound using local non-wire message id")
            }

            let message = LXMessage(
                destinationHash: sourceHash,
                sourceIdentity: nil,
                content: content.data(using: .utf8) ?? Data(),
                title: title.data(using: .utf8) ?? Data(),
                fields: fields,
                desiredMethod: method ?? .unknown
            )
            message.sourceHash = sourceHash
            message.hash = messageHash
            message.method = method ?? .unknown
            message.incoming = true
            message.timestamp = timestamp.timeIntervalSince1970
            message.state = .received
            // Receiving-interface signal metrics, captured at delivery time by
            // the Python bridge. Nil when the interface is unknown or the
            // metric is unavailable (the detail cards stay hidden). Copied onto
            // the GRDB record by `MessageRepository.mapToGRDBMessage`.
            message.rssi = rssi
            message.snr = snr

            try await repo.saveMessage(message)
            // `saveMessage` must create/update the conversation before this
            // display-name enrichment. Pre-creating it stamps the conversation
            // with a slightly newer timestamp than the inbound event, causing
            // LXMFSwift to preserve an empty lastMessagePreview and the Chats UI
            // to filter the otherwise-valid message out.
            try await repo.ensureConversation(sourceHash, displayName: displayName)
            DiagLog.log("[RNS] persistInbound saved msg=\(messageHash.prefix(4).map { String(format: "%02x", $0) }.joined())")

            // Fire the same notification IncomingMessageHandler would post
            // so ChatsViewModel / MessagingViewModel refresh.
            NotificationCenter.default.post(
                name: IncomingMessageHandler.messageReceivedNotification,
                object: nil,
                userInfo: ["sourceHash": sourceHash]
            )
            return message
        } catch {
            DiagLog.log("[RNS] persistInbound failed: \(error)")
            return nil
        }
    }

    /// Process a transaction-owned batch before a propagation sync reports
    /// completion to its caller. The Python backend temporarily pauses its
    /// normal drain loop while producing this batch.
    func processPythonEventsSynchronously(_ events: [BackendEvent]) async {
        for event in events {
            await handlePythonEvent(event)
        }
    }

    private func handlePythonEvent(_ event: BackendEvent) async {
        switch event {
        case .announce(let destHash, let appDataHex, let aspect, let publicKeysHex, let interfaceName, let hops, let t):
            guard let data = Data(hexString: destHash) else { return }
            // The bridge forwards raw app_data; decode the display name here
            // (aspect-specific layout knowledge lives in AppDataParser, not the
            // bridge). `appData` is also stashed on the PathEntry so the
            // propagation-node subsystem (PropagationNodeManager / relay badge /
            // NodeDetailsView) can parse limits + stamp cost from it.
            let appData = Data(hexString: appDataHex) ?? Data()
            let displayName = AppDataParser.displayName(from: appData, aspect: aspect)
            let configuredType = pythonInterfaceEntities.values.first {
                expectedSectionName(for: $0) == interfaceName
            }?.type
            RuntimeActivityMonitor.shared.recordAnnounce(
                interfaceName: interfaceName,
                configuredType: configuredType
            )
            DiagLog.log("[RNS] announce dest=\(destHash) aspect=\(aspect) name=\"\(displayName)\" iface=\"\(interfaceName)\" hops=\(hops)")

            // Aspect is now the SOLE signal Contact.init uses to type an
            // announce (peer / relay / audio / site) — the old app_data-shape
            // relay heuristic was removed. Both backends are expected to emit
            // one of the four known aspects (Python via per-aspect RNS
            // handlers, native via cryptographic detectedAspect). If an empty
            // or unrecognized aspect ever slips through, the announce silently
            // becomes a .peer with no fallback, so surface it loudly rather
            // than misclassifying in silence.
            let knownAspects: Set<String> = ["lxmf.delivery", "lxmf.propagation", "lxst.telephony", "nomadnetwork.node"]
            if !knownAspects.contains(aspect) {
                DiagLog.log("[RNS] WARNING: announce dest=\(destHash) has empty/unrecognized aspect=\"\(aspect)\" — will be classified as a peer. Expected one of \(knownAspects.sorted()).")
            }

            // Insert the announce into the Compat PathTable so the Contacts
            // tab's networkAnnounces list picks it up via the pathUpdates
            // AsyncStream subscription in ContactsViewModel.
            if let pathTable = self.pathTable {
                let publicKeys = Data(hexString: publicKeysHex) ?? Data()
                // Python tells us the receiving-interface section name —
                // e.g. "Hub-FFB1F1" / "Bluetooth_LE-77CFC2" / "AutoInterfacePeer".
                // Fall back to the "python-rns" sentinel only when Python
                // couldn't determine an iface (shouldn't happen post-fix).
                let ifaceId = interfaceName.isEmpty ? "python-rns" : interfaceName
                let entry = PathEntry(
                    destinationHash: data,
                    displayName: displayName,
                    nextHop: data,
                    hopCount: hops,
                    lastSeen: t,
                    publicKeys: publicKeys,
                    interfaceId: ifaceId,
                    appData: appData.isEmpty ? nil : appData,
                    expires: t.addingTimeInterval(7 * 86400),
                    timestamp: t,
                    detectedAspect: aspect,
                    isLXMFPropagationNode: aspect == "lxmf.propagation",
                    isLXSTTelephony: aspect == "lxst.telephony",
                    isKnownDestination: true
                )
                let metrics = await pathTable.insert(entry)
                RuntimeActivityMonitor.shared.recordPathTableWrite(
                    durationMilliseconds: metrics.persistenceDurationMilliseconds
                )
            }

            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonAnnounce"),
                object: nil,
                userInfo: [
                    "destinationHash": data,
                    "displayName": displayName,
                    "aspect": aspect,
                    "timestamp": t,
                ]
            )

            // Stamp the announced display name onto an EXISTING conversation
            // that still lacks one. Under Model B the NE persists an inbound
            // message — creating the conversation row with a nil display name —
            // BEFORE this announce is heard, and the app's inbound-side name
            // backfill (IncomingMessageHandler) never runs in that path, so the
            // conversation title would otherwise stay stuck on the "Peer <hash>"
            // fallback even though the announce tells us the real name. This is
            // UPDATE-only (never creates a conversation for a bare announce) and
            // only fills an empty/nil name or the exact generated hash fallback
            // (never clobbers a custom or previously announced name).
            if !displayName.isEmpty, let repo = self.messageRepository {
                if (try? await repo.applyAnnouncedDisplayName(
                    data,
                    displayName: displayName
                )) == true {
                    DiagLog.log("[RNS] stamped display name onto convo \(data.map { String(format: "%02x", $0) }.joined().prefix(8))")
                }
            }
        case .inbound(let sourceHash, let messageHash, let content, let title, let fieldsPacked, let method, let rssi, let snr, let t):
            // NO-PII: envelope/metadata only (mirrors ExtensionDiagLog's contract).
            // Never log message content, title, or field payload bytes — they land
            // in Documents/diag.log and the unified log. Hashes are prefixed to
            // keep the line correlatable without exposing full identity hashes.
            // rssi/snr are numeric radio metrics, not message content — safe to log.
            let rssiText = rssi.map { "\($0)" } ?? "-"
            let snrText = snr.map { "\($0)" } ?? "-"
            DiagLog.log("[RNS] inbound source=\(sourceHash.prefix(8)) message=\(messageHash.prefix(8)) len=\(content.utf8.count) fields=\(fieldsPacked.count)B rssi=\(rssiText) snr=\(snrText)")
            guard let data = Data(hexString: sourceHash) else { return }
            let fields = fieldsPacked.isEmpty ? nil : LxmfFieldCodec.unpack(fieldsPacked)
            // Persist the base message (carrying its fields + the receiving
            // interface's signal metrics), then run side-channel
            // handling (reactions / replies / telemetry / icon / cease) through
            // IncomingMessageHandler — the router.delegate, wired in ColumbaApp.
            // Same path for both backends (the Swift/NE backend passes nil
            // metrics; the Python backend populates them from the delivery
            // callback).
            if let saved = await persistInboundFromPython(sourceHash: data, messageHashHex: messageHash, content: content, title: title, fields: fields, method: method, rssi: rssi, snr: snr, timestamp: t),
               fields != nil, let router = self.router {
                if let handler = router.delegate as? IncomingMessageHandler {
                    _ = await handler.handleInbound(saved).value
                } else {
                    router.delegate?.router(router, didReceiveMessage: saved)
                }
            }
            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonInbound"),
                object: nil,
                userInfo: [
                    "sourceHash": data,
                    "content": content,
                    "title": title,
                    "timestamp": t,
                ]
            )
        case .state(let value, _):
            DiagLog.log("[RNS] state \(value)")
            logger.info("Python state: \(value, privacy: .public)")
        case .delivery(let messageHash, let state, let method, _):
            DiagLog.log("[RNS] delivery \(messageHash.prefix(16)) state=\(state)")
            guard let hashData = Data(hexString: messageHash) else { return }
            let newState: LXMessageState
            switch state {
            case "retrying_propagated": newState = .sending
            case "sent": newState = .sent
            case "delivered": newState = .delivered
            case "failed": newState = .failed
            default:
                logger.warning("Ignoring unknown delivery state: \(state, privacy: .public)")
                return
            }
            // Update the GRDB canonical store (where outbound messages are
            // persisted and the UI reads from), via the shared repository's
            // RNSAPI-typed method — not the Compat `database`.
            var proofPersisted = false
            // Persist the backend's effective method when provided. Only the
            // newly introduced retrying state is intrinsically propagated;
            // legacy method-less `sent` events are ambiguous and must not be
            // rewritten as relay acceptance.
            let acceptedMethod = method ?? (
                state == "retrying_propagated" ? .propagated : nil
            )
            var effectiveState = newState
            var effectiveMethod = acceptedMethod
            if let repo = self.messageRepository {
                proofPersisted = (try? await repo.applyDeliveryProof(
                    canonicalHash: hashData,
                    state: newState,
                    method: acceptedMethod
                )) ?? false
                if proofPersisted,
                   let persisted = try? await repo.persistedDeliveryProof(canonicalHash: hashData) {
                    effectiveState = persisted.state
                    effectiveMethod = persisted.method
                }
            }
            let effectiveEventState = (
                effectiveState == .sending && effectiveMethod == .propagated
            ) ? "retrying_propagated" : effectiveState.rawValue
            // Notify the open chat with the state that actually survived
            // monotonic persistence, never the rejected raw callback.
            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonDelivery"),
                object: nil,
                userInfo: [
                    "messageHash": hashData,
                    "state": effectiveEventState,
                    "deliveryMethod": effectiveMethod?.rawValue ?? "",
                    "persisted": proofPersisted,
                ]
            )
        case .linkState(let linkId, let state, let reason, let inbound, _):
            DiagLog.log("[RNS] link \(linkId) state=\(state) inbound=\(inbound)\(reason.isEmpty ? "" : " reason=\(reason)")")
            // Surface via NotificationCenter for any subscribers (debug
            // panels, smoke tests) that aren't on the Compat-Link path.
            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonLinkState"),
                object: nil,
                userInfo: [
                    "linkId": linkId,
                    "state": state,
                    "reason": reason,
                    "inbound": inbound,
                ]
            )
            // Dispatch to the Compat Link object. lxst-swift's Telephone
            // state machine + CallManager talk to Compat Links exclusively.
            let id = UInt64(linkId)
            switch state {
            case "established":
                if inbound {
                    await self.dispatchInboundLink(linkId: id)
                } else {
                    await self.dispatchOutboundLinkEstablished(linkId: id)
                }
            case "closed":
                await self.dispatchLinkClosed(linkId: id, reason: reason)
            default:
                break  // "establishing" et al — purely informational
            }
        case .linkPacket(let linkId, let data, _):
            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonLinkPacket"),
                object: nil,
                userInfo: ["linkId": linkId, "data": data]
            )
            await self.dispatchLinkPacket(linkId: UInt64(linkId), data: data)
        case .linkIdentified(let linkId, let identityHashHex, _):
            DiagLog.log("[RNS] link \(linkId) identified=\(identityHashHex.prefix(8))")
            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonLinkIdentified"),
                object: nil,
                userInfo: ["linkId": linkId, "identityHashHex": identityHashHex]
            )
            await self.dispatchLinkIdentified(linkId: UInt64(linkId), identityHashHex: identityHashHex)
        }
    }

    /// Initialize all LXMF components with an externally-provided identity.
    ///
    /// Used by multi-identity flow where IdentityManager loads the identity
    /// from Keychain and passes it in directly.
    ///
    /// - Parameters:
    ///   - identity: Pre-loaded Reticulum identity with private keys
    ///   - identityHash: Hex hash of the identity (used for DB filename)
    ///   - tcpServerAddress: TCP server address (e.g., "10.0.0.1:4242")
    public func initialize(identity: Identity, identityHash: String, tcpServerAddress: String) async throws {
        try await withLifecycleOperation {
            try await initializeUnlocked(
                identity: identity,
                identityHash: identityHash,
                tcpServerAddress: tcpServerAddress
            )
        }
    }

    private func initializeUnlocked(
        identity: Identity,
        identityHash: String,
        tcpServerAddress: String
    ) async throws {
        DiagLog.log("[STARTUP] AppServices identity initialization beginning")
        let monitorLease = RuntimeActivityMonitor.shared.acquire()
        var initializationSucceeded = false
        defer {
            if initializationSucceeded {
                retainRuntimeActivityMonitorLease(monitorLease)
            } else {
                RuntimeActivityMonitor.shared.release(monitorLease)
            }
        }
        DiagLog.log("[INIT2] Starting with identity: \(identityHash), tcp: \(tcpServerAddress)")

        self.identity = identity
        self.localIdentityHashHex = localIdentityHash.map { String(format: "%02x", $0) }.joined()
        // Model B: make this identity reachable by the in-NE node. This overload
        // receives the identity pre-loaded (multi-identity path) and never calls
        // loadOrCreateIdentity, so do the NE-sharing here.
        #if COLUMBA_RUNTIME_MODEL_B
        Self.shareIdentityForModelB(identity)
        #endif

        // 2. Create path table for routing with persistence
        let pathDbPath = Self.pathTableFilePath
        let newPathTable = try PathTable(databasePath: pathDbPath)
        self.pathTable = newPathTable

        // 3. Create transport with path table
        let newTransport = ReticulumTransport(pathTable: newPathTable)
        self.transport = newTransport
        await configureTransportCallbacks(newTransport)
        await newTransport.registerPathRequestHandler()

        // 4. Create persistent LXMF database (per-identity; RNSAPI Compat store
        //    used for IncomingMessageHandler / CallManager sender lookups).
        let dbPath = Self.databaseFilePath(for: identityHash)
        let newDatabase = try LXMFDatabase(path: dbPath)
        self.database = newDatabase

        // 4b. Open the GRDB canonical store the Swift/NE backend writes (keyed
        //     by the same identity hash startPythonBackend uses for configDir),
        //     so the UI reads the same messages. Store lives in the shared
        //     App-Group container (Model B / A2); migrate any pre-existing
        //     process-local store over BEFORE opening it.
        Self.migrateLXMFDatabaseToAppGroupIfNeeded(identityHashHex: identityHash)
        let grdbPath = Self.grdbDatabaseFilePath(for: identityHash)
        self.grdbDatabasePath = grdbPath
        let messageRepository = try MessageRepository(grdbPath: grdbPath)
        self.messageRepository = messageRepository
        let recoveredRetryCount = try await messageRepository.recoverInterruptedRetries()
        if recoveredRetryCount > 0 {
            logger.warning("Recovered \(recoveredRetryCount, privacy: .public) interrupted message retries")
        }

        // 5. Create LXMRouter with identity and database path
        let newRouter = try await LXMRouter(identity: identity, databasePath: dbPath)
        self.router = newRouter

        // 6. Create and register LXMF delivery destination
        let newDestination = Destination(
            identity: identity,
            appName: "lxmf",
            aspects: ["delivery"],
            type: .single,
            direction: .in
        )
        self.deliveryDestination = newDestination
        await newTransport.registerDestination(newDestination)

        // 6b. Enable ratchets for forward secrecy
        let ratchetPath = Self.ratchetStoragePath(for: identityHash)
        try await newDestination.enableRatchets(storagePath: ratchetPath)

        // 7. Set transport on router
        await newRouter.setTransport(newTransport)
        await newRouter.setRatchetManager(newDestination.ratchetManager)

        #if os(iOS)
        DiagLog.log("[INIT2] Step 7b: creating CallManager")
        let cm = CallManager()
        await cm.initialize(identity: identity, transport: newTransport, pathTable: newPathTable, database: newDatabase)
        self.callManager = cm
        DiagLog.log("[INIT2] Step 7b done, telephonyDest=\(cm.telephonyDestination?.hexHash ?? "nil")")
        #endif

        // 8. Parse server address and create TCP interface
        if let (host, port) = parseHostPort(tcpServerAddress) {
            let config = InterfaceConfig(
                id: "tcp-server",
                name: "TCP Server",
                type: .tcp,
                enabled: true,
                mode: .full,
                host: host,
                port: port
            )
            do {
                let newInterface = try TCPInterface(config: config)
                tcpInterfaces["tcp-server"] = newInterface
                try await newTransport.addInterface(newInterface)
                // Record the applied endpoint only after the interface
                // has been successfully attached. See the matching catch
                // block below — same rationale as the first overload.
                tcpEndpoints["tcp-server"] = TCPEndpoint(host: host, port: port)
            } catch {
                // Non-fatal: init proceeds without TCP. But roll back
                // any partial dictionary writes so a later
                // reconnectTCPOnly retry with the same address doesn't
                // hit a stuck idempotency guard in connectTCPInterface
                // and silently no-op. See the first initialize overload
                // for the full rationale.
                tcpInterfaces.removeValue(forKey: "tcp-server")
                tcpEndpoints.removeValue(forKey: "tcp-server")
                logger.warning("TCP interface failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 9. Register delivery destination with router
        try await newRouter.registerDeliveryDestination(newDestination)

        startStateObserver()

        // 10. Restore propagation preferences now; activate listener,
        // periodic, and auto-announce tasks only after backend readiness.
        let propManager = PropagationNodeManager(appServices: self)
        self.propagationManager = propManager
        await propManager.loadPreferences()

        // Dump all registered destinations and link callbacks for diagnostics.
        // Registered destinations now come from the active backend's neutral
        // `RnsCore` seam (the backend-agnostic source of truth both backends
        // share — the same set the NE's destination filter matches), not the
        // dead Compat-layer transport stub which always returned [].
        let regDests = await self.backend?.core.registeredDestinationHashes() ?? []
        let regCallbacks = await newTransport.registeredLinkCallbackHashes()
        DiagLog.log("[INIT2] Registered destinations: \(regDests)")
        DiagLog.log("[INIT2] Registered link callbacks: \(regCallbacks)")
        // Apply persisted transport mode setting
        if SharedDefaults.suite.bool(forKey: "transport_enabled") {
            await newTransport.setTransportEnabled(true, identity: identity)
            DiagLog.log("[INIT2] Transport mode enabled")
        }

        #if COLUMBA_RUNTIME_MODEL_B
        // 12. Set up extension frame reader for background transport
        let reader = ExtensionFrameReader()
        self.extensionFrameReader = reader

        // Wire frame injection: extension sends unframed packets -> transport
        let tcpId = await tcpInterface?.id ?? "ext-tcp"
        let autoId = await autoInterface?.id ?? "ext-auto"

        reader.onTCPFrameReceived = { [weak self] data in
            guard let transport = self?.transport else { return }
            Task { await transport.handleReceivedData(data: data, from: tcpId) }
        }

        reader.onAutoFrameReceived = { [weak self] data in
            guard let transport = self?.transport else { return }
            Task { await transport.handleReceivedData(data: data, from: autoId) }
        }

        reader.startListening()

        // 13. Tunnel manager (idempotent — the onboarding background-delivery step may
        //     have already created it and brought the tunnel up).
        await ensureTunnelManager()
        #endif

        // Start the backend, then activate initialization-owned manager tasks.
        try await InitializationLifecycleActivation.run(
            readiness: {
                try await self.startPythonBackend(
                    identity: identity,
                    identityHashHex: identityHash,
                    router: newRouter,
                    interfaces: InterfaceRepository().getEnabledInterfaces(),
                    displayName: ""
                )
            },
            activate: {
                self.activateInitializationManagers(propManager)
            }
        )

        // On-device test instrumentation: listen for the test-announce Darwin
        // notification now that the backend is up (see helper docs). Idempotent.
        registerTestAnnounceObserver()

        initializationSucceeded = true
        DiagLog.log("[INIT2] Initialization complete (identity: \(identityHash))")
    }

    #if COLUMBA_RUNTIME_MODEL_B
    /// Switch every TCPInterface and AutoInterface into or out of
    /// tunnel mode in response to the VPN extension's status.
    ///
    /// In tunnel mode the interface tears down its own NWConnection
    /// and routes outbound bytes through `TunnelManager.sendFrame`,
    /// which the extension forwards on its authoritative socket.
    /// Inbound continues to flow via `ExtensionFrameReader` →
    /// `transport.handleReceivedData` regardless.
    @MainActor
    private func applyTunnelModeToInterfaces(active: Bool) async {
        guard let tunnel = tunnelManager else { return }
        tunnelModeActive = active

        // Tunnel mode is TCP-only. The AutoInterface is deliberately NOT bridged:
        // forwarding its frames to `tunnel.sendFrame(tag: .auto)` black-holes them
        // — PacketTunnelProvider drops every non-ProxyRequest frame, and the NE
        // node has no UDP/Auto path to send them on anyway. Leaving Auto in its
        // local mode keeps its own foreground LAN socket working; tunneling it can
        // only break background Auto outbound. (ports #57 d3719c2 fix #3)
        if active {
            for (_, iface) in tcpInterfaces {
                await iface.beginTunnelMode { [weak tunnel] frame in
                    DiagLog.log("[BRIDGE-OUT] iface->sendFrame tag=tcp len=\(frame.count)")
                    await tunnel?.sendFrame(frame, interfaceTag: FrameInterfaceTag.tcp.rawValue)
                }
            }
            DiagLog.log("[TUNNEL] enabled tunnel mode on \(self.tcpInterfaces.count) TCP interface(s); Auto stays local")
        } else {
            for (_, iface) in tcpInterfaces {
                await iface.endTunnelMode()
            }
            DiagLog.log("[TUNNEL] disabled tunnel mode; interfaces resuming local connections")
        }
    }

    /// Whether tunnel mode is currently active (background-transport tunnel
    /// connected + interfaces bridged through the extension). Tracked so
    /// `applyInterfaceChanges` can bring interfaces hot-added *after* the tunnel
    /// came up into tunnel mode — `onStatusChange` only fires on VPN state changes,
    /// not on interface changes.
    @MainActor private var tunnelModeActive = false

    /// Re-assert tunnel mode on the current interface set if the tunnel is up.
    /// Called after a hot-reload so a freshly added interface doesn't get stranded
    /// in local-socket mode (black-holed by the active packet tunnel).
    @MainActor
    private func reapplyTunnelModeIfActive() async {
        guard tunnelModeActive else { return }
        await applyTunnelModeToInterfaces(active: true)
    }
    #endif

    /// Switch to a different identity, tearing down and re-initializing the full stack.
    ///
    /// - Parameters:
    ///   - newIdentity: The identity to switch to (already loaded from Keychain)
    ///   - identityHash: Hex hash of the new identity
    ///   - tcpServerAddress: TCP server address to reconnect to
    public func switchIdentity(to newIdentity: Identity, identityHash: String, tcpServerAddress: String) async throws {
        try await withLifecycleOperation {
            try await switchIdentityUnlocked(
                to: newIdentity,
                identityHash: identityHash,
                tcpServerAddress: tcpServerAddress
            )
        }
    }

    private func switchIdentityUnlocked(
        to newIdentity: Identity,
        identityHash: String,
        tcpServerAddress: String
    ) async throws {
        logger.info("Switching identity to: \(identityHash)")

        // Tear down current stack
        await shutdownUnlocked()

        // NOTE: Path table is NOT cleared here — path entries (announce routes)
        // are identity-agnostic and remain valid across identity switches.
        // Only reconnect() clears paths (different network = stale routes).

        // Small delay to ensure clean shutdown
        try? await Task.sleep(for: .milliseconds(200))

        // Re-initialize with new identity
        try await initializeUnlocked(
            identity: newIdentity,
            identityHash: identityHash,
            tcpServerAddress: tcpServerAddress
        )

        logger.info("Identity switch complete: \(identityHash)")
    }

    /// Activate initialization-owned manager tasks only after backend and
    /// persisted propagation-node readiness have both succeeded.
    private func activateInitializationManagers(_ propManager: PropagationNodeManager) {
        propManager.startListening()
        propManager.startPeriodicSync()
        let announceManager = AutoAnnounceManager(appServices: self)
        self.autoAnnounceManager = announceManager
        announceManager.start()
    }

    // MARK: - State Observation

    /// Start observing interface state for UI updates.
    ///
    /// Uses Task.detached to read actor-isolated properties off the main thread,
    /// then batches all @MainActor property mutations into a single MainActor.run.
    private func startStateObserver() {
        stateObserverTask?.cancel()
        stateObserverTask = Task.detached { [weak self] in
            // Track the last error we reported to avoid spamming logs
            var lastReportedError: String?

            // Poll interface state periodically
            // (TCPInterface doesn't expose AsyncStream for state changes)
            while !Task.isCancelled {
                guard let self = self else { return }

                // Read actor-isolated properties OFF the main thread
                let allTCPInterfaces = await MainActor.run { Array(self.tcpInterfaces.values) }
                let autoIface = await MainActor.run { self.autoInterface }
                let rnodeIface = await MainActor.run { self.rnodeInterface }
                let bleIface = await MainActor.run { self.bleInterface }

                // Aggregate TCP state across all interfaces
                var anyTCPConnected = false
                var anyTCPReconnecting = false
                var errorDesc: String? = nil
                for iface in allTCPInterfaces {
                    let s = await iface.state
                    if s == .connected { anyTCPConnected = true }
                    if case .reconnecting = s { anyTCPReconnecting = true }
                    if let err = await iface.lastErrorDescription { errorDesc = err }
                }
                let tcpConnected = anyTCPConnected

                // Check non-TCP interfaces
                let autoConnected: Bool
                if let auto = autoIface {
                    autoConnected = await auto.peerCount > 0
                } else {
                    autoConnected = false
                }
                let rnodeConnected: Bool
                if let rnode = rnodeIface {
                    rnodeConnected = await rnode.state == .connected
                } else {
                    rnodeConnected = false
                }
                let bleConnected: Bool
                if let ble = bleIface {
                    bleConnected = await ble.state == .connected
                } else {
                    bleConnected = false
                }

                let anyConnected = tcpConnected || autoConnected || rnodeConnected || bleConnected
                let tcpReconnecting = anyTCPReconnecting && !anyTCPConnected

                // Batch all UI mutations into a single MainActor.run
                let shouldAnnounce: Bool = await MainActor.run {
                    var needsAnnounce = false

                    if anyConnected {
                        if !self.isConnected {
                            self.isConnected = true
                            self.connectionError = nil
                            self.isReconnecting = false
                            self.logger.info("Connection state changed: connected")
                            needsAnnounce = true
                        }
                        if lastReportedError != nil {
                            lastReportedError = nil
                            self.connectionError = nil
                        }
                    } else if tcpReconnecting {
                        if self.isConnected || !self.isReconnecting {
                            self.isConnected = false
                            self.isReconnecting = true
                            self.logger.info("Connection state changed: reconnecting")
                        }
                        if let desc = errorDesc, desc != lastReportedError {
                            lastReportedError = desc
                            self.connectionError = desc
                        }
                    } else {
                        if self.isConnected || self.isReconnecting {
                            self.isConnected = false
                            self.isReconnecting = false
                            self.logger.info("Connection state changed: disconnected")
                        }
                    }

                    return needsAnnounce
                }

                // Auto-announce on connect (outside the MainActor.run to avoid blocking UI).
                // This polled path is functionally similar to the event-driven
                // `onInterfaceConnected` hook in `configureTransportCallbacks` —
                // it fires once when any interface aggregates to connected. We
                // gate both the announce *and* the resetTimer() call behind the
                // same toggles: if the announce wasn't sent, restarting the
                // periodic loop would push the next interval-announce a full
                // interval into the future every reconnect, starving the
                // periodic schedule on a flap-y network.
                if shouldAnnounce {
                    try? await Task.sleep(for: .seconds(1))
                    _ = await MainActor.run {
                        Task {
                            let policy = AutoAnnouncePolicy.current()
                            if policy.shouldFireOnTcpReconnect {
                                await self.autoAnnounce()
                                self.autoAnnounceManager?.resetTimer()
                            } else {
                                DiagLog.log("[AUTO_ANNOUNCE] state-observer connect trigger gated off (master=\(policy.masterEnabled), tcp_reconnect=\(policy.onTcpReconnect))")
                            }
                        }
                    }
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Update connection error from interface delegate.
    ///
    /// Called by the interface state observer when an error is detected.
    func setConnectionError(_ message: String) {
        connectionError = message
        logger.warning("Connection error: \(message)")
    }

    // MARK: - Utility Methods

    /// Parse "host:port" or "tcp://host:port" string into components.
    ///
    /// - Parameter address: Address string to parse
    /// - Returns: Tuple of (host, port) or nil if parsing fails
    private func parseHostPort(_ address: String) -> (String, UInt16)? {
        // Strip tcp:// prefix if present
        var cleaned = address
        if cleaned.hasPrefix("tcp://") {
            cleaned = String(cleaned.dropFirst(6))
        }

        let parts = cleaned.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            return nil
        }
        return (String(parts[0]), port)
    }

    // MARK: - Auto Interface

    /// Start the AutoInterface for LAN peer discovery.
    ///
    /// Creates an AutoInterface and adds it to the transport. If the transport
    /// or identity haven't been initialized yet, initializes the base stack first.
    ///
    /// - Parameter groupId: Group ID for peer discovery (default: "reticulum")
    public func startAutoInterface(groupId: String = "reticulum") async throws {
        try await withLifecycleOperation {
            try requireActiveRuntimeForInterfaceMutation()
            try await startAutoInterfaceUnlocked(groupId: groupId)
        }
    }

    private func startAutoInterfaceUnlocked(groupId: String = "reticulum") async throws {
        // Stop existing auto interface if any
        await stopAutoInterfaceUnlocked()

        // Ensure we have base stack (identity, transport, router)
        if transport == nil {
            try await initializeBaseStack()
        }

        guard let transport = transport else {
            throw AppServicesError.transportNotConnected
        }

        let config = InterfaceConfig(
            id: "auto0",
            name: "Auto Discovery",
            type: .autoInterface,
            enabled: true,
            mode: .full,
            host: groupId,
            port: 0
        )

        let newAutoInterface = AutoInterface(config: config)
        self.autoInterface = newAutoInterface

        try await transport.addAutoInterface(newAutoInterface)
        logger.info("AutoInterface started with group: \(groupId)")

        #if COLUMBA_RUNTIME_MODEL_B
        // Same launch-race fix as connectTCPInterface: if the tunnel is already up,
        // bring this freshly-registered interface into tunnel mode.
        await reapplyTunnelModeIfActive()
        #endif
    }

    /// Stop the AutoInterface.
    public func stopAutoInterface() async {
        await withLifecycleOperation {
            await stopAutoInterfaceUnlocked()
        }
    }

    private func stopAutoInterfaceUnlocked() async {
        guard let auto = autoInterface else { return }
        await auto.disconnect()
        if let transport = transport {
            await transport.removeInterface(id: auto.id)
        }
        autoInterface = nil
        logger.info("AutoInterface stopped")
    }

    #if canImport(CoreBluetooth)
    /// Start the BLE interface for Bluetooth peer-to-peer networking.
    ///
    /// Phase 3 flow:
    ///   1. Copy `IOSBLEInterface.py` + `IOSBLEDriver.py` from `<bundle>/app/ble/`
    ///      to `<configDir>/interfaces/` so RNS's external-interface loader can
    ///      `exec()` them when reading config.
    ///   2. Install `PythonBLECallbackBridge` as `SwiftBLEBridge.shared`'s
    ///      callback invoker so events fire through to Python's callback
    ///      registry.
    ///   3. Notify Python via `set_ble_bridge` that BLE is enabled. (Phase 3
    ///      passes a placeholder; the C-ABI shims in `BleNativeBindings.swift`
    ///      are how `IOSBLEDriver` actually calls into Swift.)
    ///   4. Update Compat-layer BLEInterface stub for the UI.
    public func startBLEInterface() async throws {
        try await withLifecycleOperation {
            try requireActiveRuntimeForInterfaceMutation()
            try await startBLEInterfaceUnlocked()
        }
    }

    private func startBLEInterfaceUnlocked() async throws {
        logger.info("[BLE_DIAG] startBLEInterface() called")

        if bleInterface != nil {
            await stopBLEInterfaceUnlocked()
            try? await Task.sleep(for: .milliseconds(500))
        }

        if transport == nil {
            logger.info("[BLE_DIAG] No transport, initializing base stack")
            try await initializeBaseStack()
        }

        guard let transport = transport, let identity = identity else {
            logger.error("[BLE_DIAG] Transport or identity nil after init")
            throw AppServicesError.transportNotConnected
        }

        let identityHash = identity.hash
        logger.info("[BLE_DIAG] Identity hash: \(identityHash.map { String(format: "%02x", $0) }.joined().prefix(16), privacy: .public)")

        // 1. Files deployed eagerly during startPythonBackend — see
        //    deployIOSBLEPythonFilesIfPossible. No-op here.

        #if COLUMBA_RUNTIME_PYTHON
        // 2. Wire Swift→Python callback bridge.
        if let backend = pythonBackend {
            let invoker = PythonBLECallbackBridge(pythonBridge: backend.pythonBridge)
            SwiftBLEBridge.shared.setCallbackInvoker(invoker)
            SwiftBLEBridge.shared.setIdentity(identityHash)
            DiagLog.log("[BLE_DIAG] PythonBLECallbackBridge installed; identity set (\(identityHash.prefix(8).map { String(format: "%02x", $0) }.joined()))")
        } else {
            DiagLog.log("[BLE_DIAG] WARNING: no pythonBackend yet — bridge invoker not installed")
        }
        #endif

        // 3. Update the Compat BLEInterface stub so UI binding has a target.
        let config = InterfaceConfig(
            id: "ble0",
            name: "Bluetooth LE",
            type: .ble,
            enabled: true,
            mode: .full,
            host: "",
            port: 0
        )
        let driver = CoreBluetoothBLEDriver(identityHash: identityHash)
        let newBLEInterface = BLEInterface(config: config, driver: driver, transportIdentity: identityHash)
        self.bleInterface = newBLEInterface

        try await transport.addBLEInterface(newBLEInterface)
        logger.info("[BLE_DIAG] BLEInterface started successfully")
    }

    /// Copy the iOS BLE mesh and RNode custom interfaces from the app bundle
    /// to `<configDir>/interfaces/` so RNS's external-interface loader can find
    /// them when reading config. Idempotent — overwrites on each call so
    /// build-time updates ship without manual cleanup.
    ///
    /// Called eagerly during `startPythonBackend` (before `backend.start()`)
    /// so the files are in place whether or not the current config has BLE
    /// enabled. A subsequent restart with BLE-enabled config then works
    /// without a separate deploy step.
    private func deployIOSBLEPythonFilesIfPossible(configDir: URL) {
        let fm = FileManager.default
        guard let bundleAppDir = Bundle.main.url(forResource: "app", withExtension: nil) else {
            DiagLog.log("[BLE_DIAG] app/ bundle resource missing — skipping deploy")
            return
        }
        let interfacesDir = configDir.appendingPathComponent("interfaces", isDirectory: true)
        do {
            try fm.createDirectory(at: interfacesDir, withIntermediateDirectories: true)
        } catch {
            DiagLog.log("[BLE_DIAG] failed to create interfaces dir: \(error)")
            return
        }

        let files = [
            (subdirectory: "ble", name: "IOSBLEInterface.py"),
            (subdirectory: "ble", name: "IOSBLEDriver.py"),
            (subdirectory: "rnode", name: "IOSRNodeInterface.py"),
            (subdirectory: "rnode", name: "IOSRNodeDriver.py")
        ]
        for file in files {
            let src = bundleAppDir
                .appendingPathComponent(file.subdirectory, isDirectory: true)
                .appendingPathComponent(file.name)
            guard fm.fileExists(atPath: src.path) else {
                DiagLog.log("[RNS_NATIVE] bundled Python interface missing: \(src.path)")
                continue
            }
            let name = file.name
            let dst = interfacesDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            do {
                try fm.copyItem(at: src, to: dst)
                DiagLog.log("[RNS_NATIVE] Deployed \(name) to \(dst.path)")
            } catch {
                DiagLog.log("[RNS_NATIVE] Failed to copy \(name): \(error)")
            }
        }
    }

    /// Stop the BLE interface.
    public func stopBLEInterface() async {
        await withLifecycleOperation {
            await stopBLEInterfaceUnlocked()
        }
    }

    private func stopBLEInterfaceUnlocked() async {
        guard let ble = bleInterface else { return }
        await ble.disconnect()
        if let transport = transport {
            await transport.removeInterface(id: ble.id)
        }
        // Tear down the Swift bridge so a subsequent start gets a clean
        // CBCentralManager / CBPeripheralManager pair. stop() now clears the
        // callbackInvoker inside its serialized queue block (to drop post-stop
        // disconnect callbacks), so no separate setCallbackInvoker(nil) here.
        SwiftBLEBridge.shared.stop()
        bleInterface = nil
        logger.info("BLEInterface stopped")
    }
    #endif

    #if canImport(MultipeerConnectivity)
    /// Start the Multipeer Connectivity interface for peer-to-peer WiFi.
    ///
    /// Discovers nearby Apple devices advertising the same service type
    /// and establishes direct peer-to-peer WiFi connections without
    /// requiring shared infrastructure.
    public func startMPCInterface() async throws {
        try await withLifecycleOperation {
            try requireActiveRuntimeForInterfaceMutation()
            try await startMPCInterfaceUnlocked()
        }
    }

    private func startMPCInterfaceUnlocked() async throws {
        await stopMPCInterfaceUnlocked()

        if transport == nil {
            try await initializeBaseStack()
        }

        guard let transport = transport, let identity = identity else {
            throw AppServicesError.transportNotConnected
        }

        let displayName = String(identity.hexHash.prefix(8))
        let config = InterfaceConfig(
            id: "mpc0",
            name: "Multipeer",
            type: .multipeerConnectivity,
            enabled: true,
            mode: .full,
            host: "reticulum",
            port: 0
        )

        let newMPCInterface = MPCInterface(config: config, displayName: displayName)
        self.mpcInterface = newMPCInterface

        try await transport.addMPCInterface(newMPCInterface)
        logger.info("MPCInterface started with display name: \(displayName)")
    }

    /// Stop the Multipeer Connectivity interface.
    public func stopMPCInterface() async {
        await withLifecycleOperation {
            await stopMPCInterfaceUnlocked()
        }
    }

    private func stopMPCInterfaceUnlocked() async {
        guard let mpc = mpcInterface else { return }
        await mpc.disconnect()
        if let transport = transport {
            await transport.removeInterface(id: mpc.id)
        }
        mpcInterface = nil
        logger.info("MPCInterface stopped")
    }
    #endif

    /// Start an RNode BLE interface with the given radio configuration.
    ///
    /// Starts the Model B App-Group RNode seam with the given radio configuration.
    /// The Python runtime keeps this shared API available but publishes a failed
    /// UI state and throws; it does not create a tunnel or restore the historical stack.
    ///
    /// - Parameters:
    ///   - config: RNode radio configuration (device name, frequency, etc.)
    ///   - name: Display name for the interface
    public func startRNodeInterface(config rnodeConfig: RNodeConfig, name: String) async throws {
        try await withLifecycleOperation {
            try requireActiveRuntimeForInterfaceMutation()
            try await startRNodeInterfaceUnlocked(config: rnodeConfig, name: name)
        }
    }

    private func startRNodeInterfaceUnlocked(config rnodeConfig: RNodeConfig, name: String) async throws {
        #if COLUMBA_RUNTIME_MODEL_B
        // Model B: the RNode protocol stack (RNodeInterface + KISS framing) runs in the
        // Network Extension — the app hosts ONLY the CoreBluetooth NUS radio. Start the
        // app-side seam server FIRST (so it's listening when the NE responds), then
        // persist the radio config for the NE, which (re)builds its RNodeInterface on
        // the change notification and drives connect/send/disconnect over the seam.
        // UI-facing Compat interface object; its `.state` is driven by the app-side
        // radio's BLE link state via the onLinkStateChange callback below (the NE owns
        // the authoritative RNodeInterface, but the BLE link state is a good proxy and
        // the app has it directly).
        let uiInterface = RNodeInterface(config: rnodeConfig, name: name)
        uiInterface.state = .connecting
        self.rnodeInterface = uiInterface

        // Watchdog: if the link never reports connected/failed — the NE never sent
        // `.connect` (config read-after-write race exhausted), or the radio scans
        // forever on a name mismatch — surface a timeout instead of a perpetual
        // "Connecting…". Cancelled in applyRNodeLinkState / stopRNodeInterface.
        rnodeConnectWatchdog?.cancel()
        rnodeConnectWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            // `try?` swallows the cancellation; be explicit so a future `await` in
            // stopRNodeInterface can't let a cancelled watchdog fire a spurious failure.
            guard !Task.isCancelled else { return }
            guard let self, let iface = self.rnodeInterface, iface.state == .connecting else { return }
            iface.state = .connectionFailed(
                underlying: "RNode didn't connect — check Bluetooth is on and Background Delivery is enabled, then try again"
            )
            NotificationObserver.postNetworkStateChanged()
        }

        guard ModelBRNodeService.shared.start(onLinkStateChange: { [weak self] linkState, reason in
            self?.applyRNodeLinkState(linkState, reason)
        }) else {
            // The failure callback is dispatched onto the next main-queue turn.
            // Stop the watchdog synchronously so it cannot later replace the
            // actionable restore-identifier failure with a generic timeout.
            rnodeConnectWatchdog?.cancel()
            rnodeConnectWatchdog = nil
            return
        }

        let seamConfig = RNodeSeamConfig(
            deviceName: rnodeConfig.deviceName,
            frequency: rnodeConfig.frequency,
            bandwidth: rnodeConfig.bandwidth,
            txPower: rnodeConfig.txPower,
            spreadingFactor: rnodeConfig.spreadingFactor,
            codingRate: rnodeConfig.codingRate,
            stAlock: rnodeConfig.stAlock,
            ltAlock: rnodeConfig.ltAlock
        )
        seamConfig.saveToAppGroup()  // posts rnodeConfigChanged → NE (re)builds its RNodeInterface

        logger.info("RNodeInterface (Model B) started: \(name)")
        #elseif COLUMBA_RUNTIME_PYTHON
        // Python owns the RNS interface + KISS/RNode protocol. The custom
        // IOSRNodeInterface loaded during backend startup drives the native
        // PythonRNodeBLEBridge, which owns only the CoreBluetooth NUS stream.
        let uiInterface = RNodeInterface(config: rnodeConfig, name: name)
        uiInterface.state = .connecting
        self.rnodeInterface = uiInterface
        PythonRNodeBLEBridge.shared.setStateHandler { [weak self] state, reason in
            DispatchQueue.main.async {
                guard let self, self.rnodeInterface === uiInterface else { return }
                switch state {
                case .disconnected:
                    self.rnodeInterface?.state = .disconnected
                case .connecting:
                    self.rnodeInterface?.state = .connecting
                case .connected:
                    self.rnodeInterface?.state = .connected
                case .failed:
                    self.rnodeInterface?.state = .connectionFailed(
                        underlying: reason ?? "RNode BLE link failed"
                    )
                }
                NotificationObserver.postNetworkStateChanged()
            }
        }
        NotificationObserver.postNetworkStateChanged()
        logger.info("RNodeInterface (Python + native BLE bridge) started: \(name)")
        #endif
    }

    /// Stop or clear the runtime's RNode interface state.
    public func stopRNodeInterface() async {
        await withLifecycleOperation {
            await stopRNodeInterfaceUnlocked()
        }
    }

    private func stopRNodeInterfaceUnlocked(closeAllPythonSessions: Bool = false) async {
        #if COLUMBA_RUNTIME_MODEL_B
        rnodeConnectWatchdog?.cancel()
        rnodeConnectWatchdog = nil
        // Clear the NE's RNode config (→ it tears down its RNodeInterface) and stop the
        // app-side radio server.
        RNodeSeamConfig.clearFromAppGroup()
        ModelBRNodeService.shared.stop()
        rnodeInterface = nil
        logger.info("RNodeInterface (Model B) stopped")
        #elseif COLUMBA_RUNTIME_PYTHON
        PythonRNodeBLEBridge.shared.setStateHandler(nil)
        if closeAllPythonSessions {
            // Full runtime shutdown happens after backend.stop() has detached
            // each Python driver. Sweep only orphaned sessions here; an
            // individual interface removal must never invalidate peers.
            PythonRNodeBLESessionRegistry.shared.closeAll()
        }
        // Also clear the legacy singleton in case an older deployed Python
        // payload opened it before the session-handle ABI was installed.
        PythonRNodeBLEBridge.shared.disconnect()
        rnodeInterface = nil
        NotificationObserver.postNetworkStateChanged()
        logger.info("RNodeInterface (Python + native BLE bridge) stopped")
        #endif
    }

    #if COLUMBA_RUNTIME_MODEL_B
    /// Reflect the app-side RNode radio's BLE link state onto the UI-facing Compat
    /// interface object + refresh the UI. The NE owns the authoritative `RNodeInterface`;
    /// the BLE link state is a good-enough proxy for the Settings "connected" indicator.
    private func applyRNodeLinkState(_ linkState: RNodeLinkState, _ reason: String?) {
        let mapped: InterfaceState
        switch linkState {
        case .disconnected: mapped = .disconnected
        case .connecting:   mapped = .connecting
        // GATED: when the NE-authoritative badge is on, the BLE link reaching `.connected`
        // is only a proxy (the NE may still be building its RNodeInterface), so hold at
        // `.connecting` and let `neRNodeStatus()` green the badge. Off → BLE link greens it.
        case .connected:    mapped = Self.rnodeBadgeFromNE ? .connecting : .connected
        case .failed:       mapped = .connectionFailed(underlying: reason ?? "RNode radio link failed")
        }
        DispatchQueue.main.async { [weak self] in
            self?.rnodeInterface?.state = mapped
            // The link reported a definitive state — stand the connect watchdog down.
            if case .connecting = mapped {} else {
                self?.rnodeConnectWatchdog?.cancel()
                self?.rnodeConnectWatchdog = nil
            }
            NotificationObserver.postNetworkStateChanged()
        }
    }
    #endif


    /// Initialize the base stack (identity, transport, router) without a TCP interface.
    ///
    /// Used when starting only AutoInterface without a TCP server.
    private func initializeBaseStack() async throws {
        // 1. Identity
        if identity == nil {
            let newIdentity = Self.loadOrCreateIdentity()
            self.identity = newIdentity
            self.localIdentityHashHex = localIdentityHash.map { String(format: "%02x", $0) }.joined()
            logger.info("Using identity: \(newIdentity.hexHash)")
        }

        guard let existingIdentity = identity else {
            throw AppServicesError.identityNotInitialized
        }

        // 2. Path table
        if pathTable == nil {
            let pathDbPath = Self.pathTableFilePath
            let newPathTable = try PathTable(databasePath: pathDbPath)
            self.pathTable = newPathTable
        }

        // 3. Transport
        if transport == nil, let pt = pathTable {
            let newTransport = ReticulumTransport(pathTable: pt)
            self.transport = newTransport
            await configureTransportCallbacks(newTransport)
        }

        // 4. Database (RNSAPI Compat store)
        if database == nil {
            let dbPath = Self.databaseFilePath
            let newDatabase = try LXMFDatabase(path: dbPath)
            self.database = newDatabase
        }

        // 4b. GRDB canonical store (matches the Swift/NE backend path). Store lives
        //     in the shared App-Group container (Model B / A2); migrate any
        //     pre-existing process-local store over BEFORE opening it.
        if messageRepository == nil {
            Self.migrateLXMFDatabaseToAppGroupIfNeeded(identityHashHex: existingIdentity.hexHash)
            let grdbPath = Self.grdbDatabaseFilePath(for: existingIdentity.hexHash)
            self.grdbDatabasePath = grdbPath
            let messageRepository = try MessageRepository(grdbPath: grdbPath)
            self.messageRepository = messageRepository
            let recoveredRetryCount = try await messageRepository.recoverInterruptedRetries()
            if recoveredRetryCount > 0 {
                logger.warning("Recovered \(recoveredRetryCount, privacy: .public) interrupted message retries")
            }
        }

        // 5. Router
        if router == nil {
            let dbPath = Self.databaseFilePath
            let newRouter = try await LXMRouter(identity: existingIdentity, databasePath: dbPath)
            self.router = newRouter
        }

        // 6. Delivery destination
        if deliveryDestination == nil {
            let newDestination = Destination(
                identity: existingIdentity,
                appName: "lxmf",
                aspects: ["delivery"],
                type: .single,
                direction: .in
            )
            self.deliveryDestination = newDestination
        }

        // Wire up transport <-> router
        if let transport = transport, let dest = deliveryDestination {
            await transport.registerDestination(dest)
        }
        if let router = router, let transport = transport {
            await router.setTransport(transport)
            if let dest = deliveryDestination {
                try await router.registerDeliveryDestination(dest)
            }
        }

        // Apply persisted transport mode setting
        if let transport, SharedDefaults.suite.bool(forKey: "transport_enabled") {
            await transport.setTransportEnabled(true, identity: existingIdentity)
        }

        // Start state observer if not running
        if stateObserverTask == nil {
            startStateObserver()
        }

        // Init propagation manager if needed
        if propagationManager == nil {
            let propManager = PropagationNodeManager(appServices: self)
            self.propagationManager = propManager
            propManager.startListening()
            await propManager.loadPreferences()
            propManager.startPeriodicSync()
        }

        #if os(iOS)
        if callManager == nil, let identity = self.identity, let transport = self.transport, let pt = pathTable, let db = database {
            let cm = CallManager()
            await cm.initialize(identity: identity, transport: transport, pathTable: pt, database: db)
            self.callManager = cm
        }
        #endif

        // Init auto-announce manager if needed
        if autoAnnounceManager == nil {
            let announceManager = AutoAnnounceManager(appServices: self)
            self.autoAnnounceManager = announceManager
            announceManager.start()
        }
    }

    // MARK: - BLE Connection Info

    #if canImport(CoreBluetooth)
    /// Get snapshot of all BLE peer connection info for UI display.
    ///
    /// The actual peer state lives in `SwiftBLEBridge.shared` — that's the
    /// process-wide CoreBluetooth singleton our Python `IOSBLEDriver` calls
    /// into via ctypes. Compat's `BLEInterface.getConnectionInfos()` was a
    /// `[]` stub, which is why BLEConnectionsView showed nothing even when
    /// a peer was visible in Network Status. Map the bridge's
    /// `BleConnectionDetails` → `BLEConnectionInfo` here so the dedicated
    /// connections screen renders real peers.
    public func getBLEConnectionInfos() async -> [BLEConnectionInfo] {
        // Model B: the BLE radio + reticulum-swift `BLEInterface` run across the NE
        // seam, NOT `SwiftBLEBridge` (the Model A Python-path CoreBluetooth
        // singleton). Query the NE's native peers over the proxy IPC. The Model A
        // `SwiftBLEBridge` path below only applies when Model B is off.
        if BackendPreference.modelB {
            return await backend?.bleConnections() ?? []
        }
        guard bleInterface != nil else { return [] }
        let details = SwiftBLEBridge.shared.getConnectionDetails()
        // Group by identity. When a peer is connected via BOTH central
        // and peripheral roles (each direction opens its own GATT link),
        // we get two entries with the same identity hash. Pick the
        // peripheral entry when present (typically the established path
        // with higher MTU), but BORROW the RSSI from the central entry
        // since CB doesn't expose central-side RSSI to a peripheral.
        var rep: [String: BleConnectionDetails] = [:]
        var rssiByIdentity: [String: Int] = [:]
        var earliestConnectedAt: [String: Date] = [:]
        for d in details {
            guard let id = d.identityHashHex else { continue }
            if let r = d.rssi { rssiByIdentity[id] = r }
            // Earliest connectedAt of all the GATT paths to this peer —
            // closer to "when we first established with them".
            if let existing = earliestConnectedAt[id] {
                earliestConnectedAt[id] = min(existing, d.connectedAt)
            } else {
                earliestConnectedAt[id] = d.connectedAt
            }
            if let existing = rep[id] {
                if d.role == .peripheral && existing.role != .peripheral {
                    rep[id] = d
                } else if d.mtu > existing.mtu {
                    rep[id] = d
                }
            } else {
                rep[id] = d
            }
        }
        let now = Date()
        return rep.values.map { d in
            let idHex = d.identityHashHex ?? d.address
            let displayName = d.identityHashHex.map { String($0.prefix(8)) }
            // Merge: prefer the picked entry's RSSI, else the borrowed
            // central-side value, else nil.
            let rssi = d.rssi ?? d.identityHashHex.flatMap { rssiByIdentity[$0] }
            let startedAt = d.identityHashHex.flatMap { earliestConnectedAt[$0] } ?? d.connectedAt
            return BLEConnectionInfo(
                identityHex: idHex,
                identityHash: idHex,
                displayName: displayName,
                rssi: rssi,
                connected: true,
                lastSeen: d.lastActivity,
                lastActivity: d.lastActivity,
                connectionType: d.role.rawValue,
                connectionDuration: max(0, now.timeIntervalSince(startedAt)),
                isOutgoing: d.role == .central,
                mtu: d.mtu,
                bytesSent: 0,
                bytesReceived: 0,
                packetsSent: 0,
                packetsReceived: 0,
                signalQuality: signalQuality(forRssi: rssi)
            )
        }
    }

    /// Map RSSI dBm to a coarse signal-quality bucket. Thresholds borrowed
    /// from the existing BLEDevicePickerSheet indicator (60/75/90 dBm steps).
    private func signalQuality(forRssi rssi: Int?) -> SignalQuality {
        guard let rssi else { return .unknown }
        let absRssi = abs(rssi)
        if absRssi < 60 { return .excellent }
        if absRssi < 75 { return .good }
        if absRssi < 90 { return .fair }
        return .poor
    }

    /// Disconnect a specific BLE peer.
    public func disconnectBLEPeer(identityHex: String) async {
        await withLifecycleOperation {
            await disconnectBLEPeerUnlocked(identityHex: identityHex)
        }
    }

    private func disconnectBLEPeerUnlocked(identityHex: String) async {
        // Resolve identity → address via the bridge; if found, ask the
        // bridge to drop the GATT connection. The Compat stub's
        // disconnectPeer was a no-op, so this is the path that actually
        // closes the link.
        if let address = SwiftBLEBridge.shared.getPeerAddress(identityHashHex: identityHex) {
            SwiftBLEBridge.shared.disconnect(address: address)
        }
    }

    /// Whether BLE interface is currently active.
    public var isBLEActive: Bool {
        bleInterface != nil
    }
    #endif

    // MARK: - Shutdown

    /// Shutdown all services gracefully.
    ///
    /// Disconnects the TCP interface, shuts down the router, and cleans up resources.
    public func shutdown() async {
        await withLifecycleOperation {
            await shutdownUnlocked()
        }
    }

    private func shutdownUnlocked() async {
        logger.info("Shutting down AppServices")

        stateObserverTask?.cancel()
        stateObserverTask = nil

        #if COLUMBA_RUNTIME_MODEL_B
        // The BLE driver's identity hash is fixed at construction. Tear it down on every
        // backend shutdown so identity switching cannot keep advertising the old identity;
        // the subsequent initialize() starts a fresh driver with the new identity hash.
        ModelBBLEService.shared.stop()
        #endif

        #if os(iOS)
        // Stop call manager: ends any active CallKit call and tears down the
        // Telephone actor + audio session. Nil it afterwards so a later
        // initialize() (e.g. identity-change / "Apply & Restart") recreates a
        // fresh instance — initialize() guards creation on `callManager == nil`,
        // and CallManager.shutdown() guts the instance (telephone/callKitManager
        // set to nil), so reusing it would leave telephony dead.
        await callManager?.shutdown()
        callManager = nil
        #endif

        // Stop Python event drain and tear down the Python RNS stack
        pythonEventTask?.cancel()
        pythonEventTask = nil
        pythonStatusPollTask?.cancel()
        pythonStatusPollTask = nil
        // Remove the test-deeplink NotificationCenter observers registered in
        // startPythonBackend(); without this they'd accumulate across restart
        // cycles and fire each handler once per past start.
        for token in pythonNotificationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        pythonNotificationObservers.removeAll()
        // Remove the test-announce Darwin observer so a re-init re-registers
        // cleanly instead of stacking callbacks (no-op if never registered).
        unregisterTestAnnounceObserver()
        // Drop stale Compat Link records. Python assigns link IDs sequentially
        // from 0 on each fresh backend, so without this a post-restart inbound
        // link (id 0, 1, …) would collide with a dead entry and dispatchInbound
        // Link would fire the established callback on the stale link instead of
        // creating a new one — silently dropping the first call(s) after a
        // restart cycle.
        activeLinksByLinkId.removeAll()
        // Clear the rest of the per-backend session state so an identity-change
        // restart starts clean: stale destination-link callbacks (keyed by the
        // old identity's telephony hash) would otherwise linger and get fanned
        // an inbound link alongside the new one, and the interface-status map
        // would mismatch the freshly-attached interfaces.
        destinationLinkCallbacks.removeAll()
        pythonInterfaceEntities.removeAll()
        if let backend = backend {
            await backend.stop()
            self.backend = nil
        }

        // Stop auto-announce manager
        autoAnnounceManager?.stop()

        // Stop propagation manager
        propagationManager?.stopListening()
        propagationManager?.stopPeriodicSync()

        // Shutdown router first (stops processing loop)
        await router?.shutdown()

        // Disconnect all TCP interfaces
        await stopTCPInterfaceUnlocked()

        // Stop RNode interface and sweep any orphaned native sessions after
        // backend.stop() detached the per-interface Python drivers above.
        await stopRNodeInterfaceUnlocked(closeAllPythonSessions: true)

        // Stop BLE interface
        #if canImport(CoreBluetooth)
        await stopBLEInterfaceUnlocked()
        #endif

        // Stop auto interface
        await stopAutoInterfaceUnlocked()

        isConnected = false
        releaseRuntimeActivityMonitorLease()
        logger.info("AppServices shutdown complete")
    }

    /// Connect a TCP interface by entity ID, replacing any existing one with the same ID.
    ///
    /// Multiple concurrent TCP interfaces are supported — each entity ID is independent.
    /// Idempotent: if an interface is already running for `entityId` with the same
    /// `host:port`, returns without disturbing it.
    public func connectTCPInterface(entityId: String, host: String, port: UInt16) async throws {
        try await withLifecycleOperation {
            try requireActiveRuntimeForInterfaceMutation()
            try await connectTCPInterfaceUnlocked(entityId: entityId, host: host, port: port)
        }
    }

    private func connectTCPInterfaceUnlocked(entityId: String, host: String, port: UInt16) async throws {
        let endpoint = TCPEndpoint(host: host, port: port)

        // Already running with the same endpoint — leave it alone.
        if tcpInterfaces[entityId] != nil, tcpEndpoints[entityId] == endpoint {
            return
        }

        // Stop any existing interface with this entity ID (config changed)
        if let existing = tcpInterfaces[entityId] {
            await existing.disconnect()
            await transport?.removeInterface(id: entityId)
            tcpInterfaces.removeValue(forKey: entityId)
            tcpEndpoints.removeValue(forKey: entityId)
        }

        // Ensure base stack exists
        if transport == nil {
            try await initializeBaseStack()
        }
        guard let transport = transport else {
            throw AppServicesError.transportNotConnected
        }

        let config = InterfaceConfig(
            id: entityId,
            name: "TCP Server",
            type: .tcp,
            enabled: true,
            mode: .full,
            host: host,
            port: port
        )
        let newInterface = try TCPInterface(config: config)
        tcpInterfaces[entityId] = newInterface
        do {
            try await transport.addInterface(newInterface)
        } catch {
            // addInterface failed — roll back the dictionary write so a
            // retry with the same endpoint isn't silently no-op'd by the
            // idempotency guard at the top of this function. Without
            // this cleanup, a transient addInterface failure would leave
            // a stuck entry that permanently blocks self-healing
            // reconnects for this entityId until the user edits its
            // host or port.
            tcpInterfaces.removeValue(forKey: entityId)
            throw error
        }
        // Only record the applied endpoint after the interface has been
        // successfully attached to the transport — see the catch block
        // above for the reasoning.
        tcpEndpoints[entityId] = endpoint

        if let dest = deliveryDestination {
            await transport.registerDestination(dest)
        }

        if let router = router {
            await router.setTransport(transport)
            await router.restart()
            if let dest = deliveryDestination {
                try? await router.registerDeliveryDestination(dest)
            }
        }

        if let identity = identity, SharedDefaults.suite.bool(forKey: "transport_enabled") {
            await transport.setTransportEnabled(true, identity: identity)
        }

        startStateObserver()

        #if COLUMBA_RUNTIME_MODEL_B
        // Launch-race fix: the persistent background-transport tunnel can already be
        // `.connected` when the app cold-starts, so `onStatusChange` fires (and tunnel
        // mode is applied) BEFORE this interface is registered — leaving it in
        // local-socket mode, black-holed by the active packet tunnel (connected,
        // rx=0 tx=0, no announces). Re-assert tunnel mode now that this interface
        // exists so it's bridged through the extension.
        await reapplyTunnelModeIfActive()
        #endif
    }

    /// Stop a specific TCP interface by entity ID.
    public func stopTCPInterface(entityId: String) async {
        await withLifecycleOperation {
            await stopTCPInterfaceUnlocked(entityId: entityId)
        }
    }

    private func stopTCPInterfaceUnlocked(entityId: String) async {
        guard let interface = tcpInterfaces[entityId] else { return }
        await interface.disconnect()
        await transport?.removeInterface(id: entityId)
        tcpInterfaces.removeValue(forKey: entityId)
        tcpEndpoints.removeValue(forKey: entityId)
    }

    /// Stop all TCP interfaces.
    public func stopTCPInterface() async {
        await withLifecycleOperation {
            await stopTCPInterfaceUnlocked()
        }
    }

    private func stopTCPInterfaceUnlocked() async {
        for (entityId, interface) in tcpInterfaces {
            await interface.disconnect()
            await transport?.removeInterface(id: entityId)
        }
        tcpInterfaces.removeAll()
        tcpEndpoints.removeAll()
        isConnected = false
    }

    /// Reconnect only the TCP interface without tearing down BLE/Auto/RNode.
    /// Uses the legacy "tcp-server" entity ID for backward compatibility.
    public func reconnectTCPOnly(host: String, port: UInt16) async throws {
        try await withLifecycleOperation {
            try requireActiveRuntimeForInterfaceMutation()
            try await connectTCPInterfaceUnlocked(entityId: "tcp-server", host: host, port: port)
        }
    }

    // MARK: - Reconnection

    /// Reconnect to a new TCP server.
    ///
    /// This method:
    /// 1. Shuts down existing connections
    /// 2. Clears the path table (old paths invalid for new network)
    /// 3. Re-initializes with the new server address
    ///
    /// - Parameter tcpServerAddress: New TCP server address (e.g., "tcp://10.0.0.1:4242")
    /// - Throws: InterfaceError or other initialization errors
    public func reconnect(tcpServerAddress: String) async throws {
        try await withLifecycleOperation {
            try await reconnectUnlocked(tcpServerAddress: tcpServerAddress)
        }
    }

    private func reconnectUnlocked(tcpServerAddress: String) async throws {
        logger.info("Reconnecting to new TCP server: \(tcpServerAddress)")

        // 1. Shutdown existing connection
        await shutdownUnlocked()

        // 2. Clear path table (old paths may not be valid for new network)
        if let pathTable = pathTable {
            await pathTable.removeAll()
        }

        // 3. Small delay to ensure clean shutdown
        try? await Task.sleep(for: .milliseconds(100))

        // 4. Re-initialize with new address (reuses existing identity)
        try await reinitializeConnection(tcpServerAddress: tcpServerAddress)

        logger.info("Reconnection complete")
    }

    /// Re-initialize just the connection components (keeps identity).
    ///
    /// Used by reconnect() to avoid recreating identity on server change.
    private func reinitializeConnection(tcpServerAddress: String) async throws {
        guard let existingIdentity = identity else {
            throw AppServicesError.identityNotInitialized
        }

        let monitorLease = RuntimeActivityMonitor.shared.acquire()
        var reinitializationSucceeded = false
        defer {
            if reinitializationSucceeded {
                retainRuntimeActivityMonitorLease(monitorLease)
            } else {
                RuntimeActivityMonitor.shared.release(monitorLease)
            }
        }

        // Parse server address
        guard let (host, port) = parseHostPort(tcpServerAddress) else {
            throw AppServicesError.invalidServerAddress(tcpServerAddress)
        }

        logger.info("Connecting to \(host):\(port)")

        // Create new path table with persistence (or reuse existing if already loaded)
        let pathDbPath = Self.pathTableFilePath
        let newPathTable = try PathTable(databasePath: pathDbPath)
        self.pathTable = newPathTable
        logger.info("Created PathTable with persistence: \(pathDbPath)")

        // Create new transport with path table
        let newTransport = ReticulumTransport(pathTable: newPathTable)
        self.transport = newTransport
        await configureTransportCallbacks(newTransport)

        // Re-register delivery destination if it exists
        if let dest = deliveryDestination {
            await newTransport.registerDestination(dest)
        }

        // Create and connect new TCP interface
        let config = InterfaceConfig(
            id: "tcp-server",
            name: "TCP Server",
            type: .tcp,
            enabled: true,
            mode: .full,
            host: host,
            port: port
        )
        let newInterface = try TCPInterface(config: config)
        tcpInterfaces["tcp-server"] = newInterface

        // Add interface to transport (connects it)
        do {
            try await newTransport.addInterface(newInterface)
        } catch {
            // addInterface failed — roll back the dictionary write so a
            // retry via reconnectTCPOnly with the same address isn't
            // silently no-op'd by connectTCPInterface's idempotency
            // guard. See connectTCPInterface's catch block for the full
            // rationale.
            tcpInterfaces.removeValue(forKey: "tcp-server")
            throw error
        }
        // Only record the applied endpoint after the interface has been
        // successfully attached to the transport.
        tcpEndpoints["tcp-server"] = TCPEndpoint(host: host, port: port)

        // Set transport on router and re-register delivery destination
        if let router = router {
            await router.setTransport(newTransport)

            // Restart router to clear shutdown flag from previous disconnect
            await router.restart()

            // Re-register delivery destination to receive inbound LXMF messages
            if let dest = deliveryDestination {
                try await router.registerDeliveryDestination(dest)
            }
        }

        // Apply persisted transport mode setting
        if SharedDefaults.suite.bool(forKey: "transport_enabled") {
            await newTransport.setTransportEnabled(true, identity: existingIdentity)
        }

        // Restart state observer
        startStateObserver()

        reinitializationSucceeded = true
        logger.info("Connection re-initialized to \(host):\(port)")
    }

    // MARK: - Announce

    /// Send an announce for this device's LXMF delivery destination.
    ///
    /// This broadcasts the device's identity to the network, allowing other peers
    /// to discover and communicate with this device. The display name is included
    /// as application data in the announce packet.
    ///
    /// - Parameter displayName: Display name to broadcast (e.g., "User's Mac")
    /// - Throws: AppServicesError if transport or destination not initialized
    public func sendAnnounce(displayName: String) async throws {
        logger.info("Sending announce with display name: \(displayName, privacy: .public)")

        // Python owns the network layer now — route the announce through
        // rns_bridge.announce(display_name), which updates the LXMF
        // delivery destination's app_data and calls .announce() under
        // the embedded CPython. The pre-Python-RNS path (Compat
        // Announce.buildPacket → transport.send) was a no-op stub.
        guard let backend = backend else {
            throw AppServicesError.transportNotConnected
        }
        let ok = try await backend.announce(displayName: displayName)
        if !ok {
            throw AppServicesError.transportNotConnected
        }
        DiagLog.log("[ANNOUNCE] sent via Python (name=\"\(displayName)\")")
    }

    /// Per-relay status for the Interface UI. Maps each registered `ne-tcp-relay-<id>`
    /// interface back to its entity id (the suffix), with online + last error so the
    /// card can show connected / unreachable / connecting per relay.
    public func neTcpRelayStatuses() async -> [(entityId: String, online: Bool, lastError: String?)] {
        guard BackendPreference.modelB, let backend = backend else { return [] }
        let snap = await backend.statusSnapshot()
        return (snap?.interfaces ?? []).compactMap { iface in
            guard iface.sectionName.hasPrefix("ne-tcp-relay-") else { return nil }
            let entityId = String(iface.sectionName.dropFirst("ne-tcp-relay-".count))
            return (entityId: entityId, online: iface.online, lastError: iface.lastError)
        }
    }

    /// NE-authoritative status for the single Model B RNode interface (`ne-rnode`, the id
    /// the NE assigns at `NEReticulumNode` setup). Returns nil when no RNode interface is in
    /// the snapshot. `lastError` only carries a real RNode reason once reticulum-swift
    /// forwards `lastErrorDescription` for RNode (B5B); until then a down RNode reads as
    /// "connecting". Consumed (gated) by `InterfaceManagementViewModel.refreshNEBackedStatus`.
    public func neRNodeStatus() async -> (online: Bool, lastError: String?)? {
        guard BackendPreference.modelB, let backend = backend else { return nil }
        let snap = await backend.statusSnapshot()
        guard let iface = (snap?.interfaces ?? []).first(where: { $0.sectionName == "ne-rnode" }) else {
            return nil
        }
        return (online: iface.online, lastError: iface.lastError)
    }

    /// Send both the LXMF delivery announce and the LXST telephony announce.
    ///
    /// This is the single entry point for all announce triggers (app start,
    /// contacts tab button, settings card button, auto-announce timer,
    /// interface added callback). Both announces use the same display name.
    ///
    /// - Parameter displayName: Display name to broadcast
    /// - Throws: AppServicesError if transport or destination not initialized
    public func sendAllAnnounces(displayName: String) async throws {
        // Send both announces independently — one failing shouldn't block the other.
        var firstError: Error?

        do {
            try await sendAnnounce(displayName: displayName)
            DiagLog.log("[ANNOUNCE] Delivery announce sent")
        } catch {
            DiagLog.log("[ANNOUNCE] Delivery announce failed: \(error.localizedDescription)")
            firstError = error
        }

        #if os(iOS)
        if let backend = backend {
            do {
                let ok = try await backend.announceTelephony(displayName: displayName)
                DiagLog.log("[ANNOUNCE] Telephony announce \(ok ? "sent" : "skipped")")
            } catch {
                DiagLog.log("[ANNOUNCE] Telephony announce failed: \(error.localizedDescription)")
                if firstError == nil { firstError = error }
            }
        }
        #endif

        if let firstError { throw firstError }
    }

    // MARK: - Test instrumentation (Darwin-notification trigger)

    /// Register a Darwin-notification observer for `network.columba.test.announce`
    /// so an on-device test harness can drive a manual announce on a physical
    /// device that Maestro/idb can't automate. The host posts the notification
    /// via `xcrun devicectl device notification post network.columba.test.announce`;
    /// on receipt this fires `sendAllAnnounces(displayName:)` (the same entry point
    /// the auto-announce path uses), passing the empty string the backend resolves
    /// to the configured display name.
    ///
    /// Idempotent: registers at most once (see `testAnnounceObserverRegistered`).
    /// Call only AFTER the backend is started, so the announce has a live stack to
    /// route through. The C callback can't capture `self`, so we pass the opaque
    /// pointer and resolve it back, then hop to the `@MainActor` to call the async
    /// announce inside a `Task` (the callback runs on a Mach-port thread).
    private func registerTestAnnounceObserver() {
        guard !testAnnounceObserverRegistered else { return }
        testAnnounceObserverRegistered = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let self_ = Unmanaged<AppServices>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DiagLog.log("[TEST-TRIGGER] test-announce Darwin notification received -> sendAllAnnounces")
                Task { @MainActor in
                    // Empty string -> backend resolves the configured display name,
                    // matching the auto-announce path.
                    try? await self_.sendAllAnnounces(displayName: "")
                }
            },
            Self.testAnnounceNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Remove the test-announce Darwin observer. Called from `shutdown()` so a
    /// re-init cycle re-registers cleanly rather than stacking callbacks.
    private func unregisterTestAnnounceObserver() {
        guard testAnnounceObserverRegistered else { return }
        testAnnounceObserverRegistered = false
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName(Self.testAnnounceNotification as CFString),
            nil
        )
    }

    /// Wire transport callbacks that need app-layer context.
    ///
    /// Auto-announce triggers are split across two reticulum-swift hooks
    /// and gated independently behind user-facing settings:
    ///
    /// - `onInterfaceConnected` fires whenever any interface transitions to
    ///   `.connected` (TCP / RNode reconnects, plus the connected transition
    ///   of peer-children). Gated by `auto_announce_on_tcp_reconnect`.
    /// - `onInterfacePeerSpawned` fires when AutoInterface / BLE / MPC
    ///   accepts a new peer. Gated by `auto_announce_on_peer_spawned`.
    ///
    /// Both are also gated behind the master `auto_announce_enabled`. If
    /// the user has disabled auto-announce entirely, neither path fires.
    private func configureTransportCallbacks(_ transport: ReticulumTransport) async {
        await transport.setOnInterfaceConnected { [weak self] id in
            guard let self else { return }
            // Attribute peer-child connected transitions to the peer-spawn
            // trigger, not tcp-reconnect: a peer joining causes both an
            // `onInterfacePeerSpawned` and (a moment later) an
            // `onInterfaceConnected` for the peer's child transport, but
            // they describe the same user-visible event.
            //
            // The lookup is synchronous (lock-protected, not actor-hop),
            // and the corresponding record on the peer-spawn side is also
            // synchronous and runs before any await — see
            // `peerChildRegistry`'s docstring for why this ordering is
            // load-bearing for the attribution.
            let isPeerChild = self.isPeerChildInterface(id)
            let policy = AutoAnnouncePolicy.current()
            guard policy.masterEnabled else {
                DiagLog.log("[AUTO_ANNOUNCE] onInterfaceConnected(\(id)) — master toggle off, skipping")
                return
            }
            guard policy.shouldFireOnInterfaceConnected(isPeerChild: isPeerChild) else {
                let gate = isPeerChild ? "on-peer-spawned (peer-child reconnect)" : "on-tcp-reconnect"
                DiagLog.log("[AUTO_ANNOUNCE] onInterfaceConnected(\(id)) — \(gate) off, skipping")
                return
            }
            let gate = isPeerChild ? "on-peer-spawned (peer-child reconnect)" : "on-tcp-reconnect"
            DiagLog.log("[AUTO_ANNOUNCE] onInterfaceConnected(\(id)) — firing via \(gate)")
            await self.autoAnnounce()
        }
        await transport.setOnInterfacePeerSpawned { [weak self] id in
            guard let self else { return }
            // Record this id so that the subsequent `onInterfaceConnected`
            // for the same id is gated by the peer-spawned trigger rather
            // than tcp-reconnect.
            //
            // SYNCHRONOUS — runs before any await suspension in this
            // closure. This guarantees that even if the peer's child
            // transport reaches `.connected` immediately and fires its own
            // Task before this one completes its policy/announce work, the
            // connected closure's `isPeerChildInterface(id)` lookup will
            // already see the recorded id. Without that synchronous
            // guarantee, the two MainActor hops would race.
            self.recordPeerChildInterface(id)
            let policy = AutoAnnouncePolicy.current()
            guard policy.masterEnabled else {
                DiagLog.log("[AUTO_ANNOUNCE] onInterfacePeerSpawned(\(id)) — master toggle off, skipping")
                return
            }
            guard policy.shouldFireOnPeerSpawned else {
                DiagLog.log("[AUTO_ANNOUNCE] onInterfacePeerSpawned(\(id)) — on-peer-spawned off, skipping")
                return
            }
            DiagLog.log("[AUTO_ANNOUNCE] onInterfacePeerSpawned(\(id)) — firing")
            await self.autoAnnounce()
        }
        // Wire diagnostic logging from transport to DiagLog
        await transport.setOnDiagnostic { msg in
            DiagLog.log(msg)
        }

        // ──── Telephony link bridge hooks ────
        //
        // Wires the Compat-layer transport calls that CallManager + the
        // lxst-swift Telephone make against PythonRNSBackend. Python owns
        // the actual RNS.Link cryptography + path discovery; Swift owns the
        // call state machine + audio. The hooks are @Sendable so they hop
        // back to the main actor before touching AppServices state.

        transport.registerDestinationLinkCallbackHook = { [weak self] destHash, callback in
            Task { @MainActor [weak self] in
                self?.registerDestinationLinkCallbackOnMain(destHash: destHash, callback: callback)
            }
        }

        transport.initiateLinkHook = { [weak self] destination, _ in
            guard let self else { throw AppServicesError.transportNotConnected }
            return try await self.openOutboundLink(to: destination)
        }
    }

    /// Hop-to-main-actor wrapper for the registerDestinationLinkCallback hook.
    private func registerDestinationLinkCallbackOnMain(
        destHash: Data,
        callback: @escaping @Sendable (Link) async -> Void
    ) {
        destinationLinkCallbacks[destHash] = callback
        DiagLog.log("[TEL_BRIDGE] registered dest-link callback for \(destHash.prefix(4).map { String(format: "%02x", $0) }.joined())")
    }

    /// Open an outbound Compat Link by asking PythonRNSBackend to open the
    /// underlying RNS.Link, then wrap it with a Swift-side Link that
    /// forwards bytes through the bridge. AppServices-isolated so the
    /// initiateLinkHook stays @Sendable-safe.
    private func openOutboundLink(to destination: Destination) async throws -> Link {
        guard let backend = self.backend else {
            throw AppServicesError.transportNotConnected
        }
        let destHex = destination.hash.toHex()
        let aspect = ([destination.appName] + destination.aspects).joined(separator: ".")
        let result = try await backend.openLink(
            destHashHex: destHex,
            aspect: aspect,
            identityPublicKeyHex: destination.identity?.publicKeyHex
        )
        guard result.ok else {
            throw AppServicesError.transportNotConnected
        }
        let linkIdRaw = UInt64(result.linkId)
        let link = Link(identityHash: destination.identity?.hash ?? Data())
        link.linkId = linkIdRaw
        let backendRef = backend
        link.sendBytesHook = { data in
            _ = try? await backendRef.linkSend(linkId: Int(linkIdRaw), data: data)
        }
        link.identifyHook = {
            try? await backendRef.linkIdentify(linkId: Int(linkIdRaw))
        }
        link.closeHook = {
            _ = try? await backendRef.linkTeardown(linkId: Int(linkIdRaw))
        }
        activeLinksByLinkId[linkIdRaw] = link
        DiagLog.log("[TEL_BRIDGE] opened outbound link \(linkIdRaw) → \(destHex.prefix(8))")
        return link
    }

    /// Map a Python link_state(closed, reason=...) value to the
    /// TeardownReason enum lxst-swift's Telephone understands. Python emits
    /// `RNS.Link.teardown_reason` directly — that's an int (0/1/2) so the
    /// bridge stringifies it before crossing. Earlier code only matched the
    /// English names, so normal hangups were silently logged as
    /// `.networkFailure`. Mirrors `RNS.Link.TIMEOUT` (0), `INITIATOR_CLOSED`
    /// (1), `DESTINATION_CLOSED` (2) in Reticulum/Link.py.
    private func teardownReason(from raw: String) -> TeardownReason {
        switch raw {
        case "0", "timeout":                            return .timeout
        case "1", "initiator_closed", "local_closed":   return .initiatorClosed
        case "2", "destination_closed", "remote_closed": return .destinationClosed
        default:                                         return .networkFailure
        }
    }

    /// Construct (or refresh) a Compat Link for an inbound Python link.
    ///
    /// Python's `_on_inbound_link` only fires for the `lxst.telephony`
    /// destination today, so this maps that event onto every registered
    /// destination-link callback. When the rns_bridge starts carrying
    /// other inbound aspects, the Python event will need to carry a
    /// destination-hash field and the dispatch should switch to a single
    /// targeted callback lookup.
    private func dispatchInboundLink(linkId: UInt64) async {
        if let existing = activeLinksByLinkId[linkId] {
            existing.state = .established
            await existing.establishedCallback?(existing)
            return
        }
        let link = Link(identityHash: Data())
        link.linkId = linkId
        link.state = .established
        if let backend = self.backend {
            let backendRef = backend
            link.sendBytesHook = { data in
                _ = try? await backendRef.linkSend(linkId: Int(linkId), data: data)
            }
            link.identifyHook = {
                try? await backendRef.linkIdentify(linkId: Int(linkId))
            }
            link.closeHook = {
                _ = try? await backendRef.linkTeardown(linkId: Int(linkId))
            }
        }
        activeLinksByLinkId[linkId] = link
        let callbacks = Array(destinationLinkCallbacks.values)

        // Python's inbound-link event carries only the linkId, not the
        // destination hash, so we can't yet route to a single matching
        // callback. Today only the lxst.telephony destination registers one,
        // so the single-callback path is correct. If a second destination ever
        // registers a link callback before the rns_bridge inbound event grows
        // a destination-hash field, fanning every inbound link out to all of
        // them would cross call state between destinations — surface that
        // loudly here rather than corrupting silently.
        if callbacks.count > 1 {
            DiagLog.log("[TEL_BRIDGE] WARNING: \(callbacks.count) destination link callbacks registered, but the Python inbound-link event has no destination hash — cannot route link \(linkId) unambiguously (needs the rns_bridge destination-hash field; see PR1)")
        }
        for callback in callbacks {
            await callback(link)
        }
        await link.establishedCallback?(link)
    }

    /// Fire the establishedCallback when Python confirms an outbound link
    /// finished its LRRTT handshake.
    private func dispatchOutboundLinkEstablished(linkId: UInt64) async {
        guard let link = activeLinksByLinkId[linkId] else { return }
        link.state = .established
        await link.establishedCallback?(link)
    }

    /// Drop a Compat Link record when Python tells us the link tore down.
    private func dispatchLinkClosed(linkId: UInt64, reason: String) async {
        let link = activeLinksByLinkId.removeValue(forKey: linkId)
        guard let link else { return }
        link.state = .closed
        await link.closeCallback?(teardownReason(from: reason))
    }

    /// Forward an inbound Python link_packet → Compat Link.packetCallback.
    private func dispatchLinkPacket(linkId: UInt64, data: Data) async {
        guard let link = activeLinksByLinkId[linkId] else { return }
        await link.packetCallback?(data, Packet(payload: data))
    }

    /// Forward Python link_identified → Compat Link.identifyCallbacks.
    private func dispatchLinkIdentified(linkId: UInt64, identityHashHex: String) async {
        guard let link = activeLinksByLinkId[linkId] else { return }
        // Build a stub Identity carrying just the remote hash so the
        // Telephone's caller-allowed check can compare bytes. The remote's
        // full public keys land in the path table separately when an
        // announce comes through; the Telephone state machine doesn't
        // need them for the allow-list check.
        guard let remoteHash = try? identityHashHex.hexToData() else { return }
        let remoteIdentity = Identity(
            hash: remoteHash,
            publicKeys: Data(),
            privateKeyBytes: nil
        )
        await link.identifyCallbacks?.remoteIdentified(remoteIdentity)
    }

    /// Timestamp of the last successful auto-announce (debounce duplicate triggers).
    private var lastAutoAnnounce: Date = .distantPast

    /// Auto-announce on interface connect using the stored display name.
    ///
    /// Sends both the LXMF delivery announce and the LXST telephony announce
    /// so peers can discover us for both messaging and voice calls.
    ///
    /// Debounced to at most once per 5 seconds — AutoInterface peers fire
    /// the connected-trigger from both the peer callback and the
    /// state-change delegate, so this prevents redundant announces.
    ///
    /// Mark an interface id as a peer-child of an AutoInterface / BLE /
    /// MPC parent so its later `onInterfaceConnected` event is attributed
    /// to the peer-spawned trigger. Safe to call from any thread; the
    /// underlying registry uses a lock, not actor isolation.
    nonisolated private func recordPeerChildInterface(_ id: String) {
        peerChildRegistry.record(id)
    }

    /// True if this interface id was previously recorded as a peer-child
    /// via `recordPeerChildInterface`. Safe to call from any thread.
    nonisolated private func isPeerChildInterface(_ id: String) -> Bool {
        peerChildRegistry.contains(id)
    }

    /// Defensive master-gate: even though every individual call site checks
    /// the master `auto_announce_enabled` toggle, this method also bails if
    /// the master is off, so a future caller that forgets to gate doesn't
    /// silently emit announces against the user's preference.
    private func autoAnnounce() async {
        guard AutoAnnouncePolicy.current().masterEnabled else {
            DiagLog.log("[AUTO_ANNOUNCE] master toggle off — skipping at autoAnnounce() entry")
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastAutoAnnounce) > 5.0 else {
            DiagLog.log("[AUTO_ANNOUNCE] debounced (last announce \(String(format: "%.1f", now.timeIntervalSince(lastAutoAnnounce)))s ago)")
            return
        }
        DiagLog.log("[AUTO_ANNOUNCE] triggered")
        let displayName = await SettingsRepository().getDisplayName()
        do {
            try await sendAllAnnounces(displayName: displayName)
            lastAutoAnnounce = Date()
            DiagLog.log("[AUTO_ANNOUNCE] completed successfully")
        } catch {
            DiagLog.log("[AUTO_ANNOUNCE] failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Initialization Lifecycle Activation

@MainActor
enum InitializationLifecycleActivation {
    static func run(
        readiness: @MainActor () async throws -> Void,
        activate: @MainActor () -> Void
    ) async throws {
        try await readiness()
        activate()
    }
}

// MARK: - Propagation Readiness

@MainActor
enum PropagationNodeRestoreReadiness {
    static func validate(
        reapplied: Bool,
        rollback: @MainActor () async -> Void
    ) async throws {
        guard reapplied else {
            await rollback()
            throw AppServicesError.propagationNodeRestoreFailed
        }
    }
}

// MARK: - Errors

/// Errors from AppServices operations.
public enum AppServicesError: Error, Equatable {
    /// Invalid server address format
    case invalidServerAddress(String)

    /// Identity not initialized
    case identityNotInitialized

    /// Router not initialized
    case routerNotInitialized

    /// Transport not connected
    case transportNotConnected

    /// Persisted propagation node could not be restored into the embedded router
    case propagationNodeRestoreFailed

}

// MARK: - CustomStringConvertible

extension AppServicesError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidServerAddress(let address):
            return "Invalid server address format: \(address)"
        case .identityNotInitialized:
            return "Identity not initialized"
        case .routerNotInitialized:
            return "Router not initialized"
        case .transportNotConnected:
            return "Transport not connected"
        case .propagationNodeRestoreFailed:
            return "Persisted propagation node could not be restored"
        }
    }
}
