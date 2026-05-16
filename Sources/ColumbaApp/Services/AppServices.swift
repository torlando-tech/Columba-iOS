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
import CryptoKit
#if os(iOS)
#endif
import os.log

/// Simple file logger for diagnostics when idevicesyslog isn't available (WiFi-only device).
/// Writes to Documents/diag.log which can be extracted via Xcode or devicectl.
enum DiagLog {
    private static let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("diag.log")
    }()

    static func clear() {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

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

    /// Convenience accessor for the first TCP interface (backward compat).
    public var tcpInterface: TCPInterface? { tcpInterfaces.values.first }

    /// RNode BLE interface for LoRa radio communication.
    public var rnodeInterface: RNodeInterface?

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

    /// LXMF database for message persistence.
    public private(set) var database: LXMFDatabase?

    /// Propagation node manager for relay discovery and sync.
    public private(set) var propagationManager: PropagationNodeManager?

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
    public private(set) var pythonBackend: PythonRNSBackend?

    /// Background task that drains Python events (announces, inbound
    /// messages) into Columba's existing UI plumbing.
    private var pythonEventTask: Task<Void, Never>?

    /// Identity used to start the Python backend. Cached so the
    /// "Apply & Restart" flow can re-boot Python after the user edits
    /// interfaces, without making AppServices re-derive it.
    private var pythonStartIdentity: Identity?

    /// Display name passed to the Python backend on start. Cached for
    /// the restart path (same reason as pythonStartIdentity).
    private var pythonStartDisplayName: String = ""

    /// Hashes we've already auto-replied to during the smoke test.
    /// Prevents a feedback loop where each sim's auto-reply triggers
    /// the other's auto-reply forever.
    private var smokeTestAutoSentTo: Set<String> = []

    /// Periodic poller that mirrors Python's RNS.Transport interface state
    /// into the Compat TCPInterface stubs so the existing
    /// NetworkStatusView / InterfaceManagementScreen show correct
    /// connected/disconnected badges. Cancelled in `shutdown()`.
    private var pythonStatusPollTask: Task<Void, Never>?

    /// Last interface snapshot key we logged, so the poll only logs
    /// changes (not every 2s tick).
    private var lastInterfaceSnapshotKey: String = ""

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

    #if ENABLE_NETWORK_EXTENSION
    /// Network Extension tunnel manager.
    public private(set) var tunnelManager: TunnelManager?

    /// Extension frame reader for processing queued frames from the extension.
    private var extensionFrameReader: ExtensionFrameReader?
    #endif

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

    // MARK: - Identity Persistence Constants

    /// Keychain service identifier for storing identity.
    private static let keychainService = "com.columba.identity"

    /// Keychain account identifier for storing identity.
    private static let keychainAccount = "reticulum-identity"

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
    /// - Returns: The loaded or newly created identity
    private static func loadOrCreateIdentity() -> Identity {
        // Try Keychain first (most secure)
        do {
            if let stored = try Identity.loadFromKeychain(
                service: keychainService,
                account: keychainAccount
            ) {
                sLogger.info("[IDENTITY] Loaded from Keychain")
                return stored
            }
        } catch {
            sLogger.warning("[IDENTITY] Keychain load error: \(error.localizedDescription)")
        }

        // Try file-based storage (fallback)
        if let stored = loadIdentityFromFile() {
            sLogger.info("[IDENTITY] Loaded from file")
            return stored
        }

        // Create new identity
        let created = Identity()
        sLogger.info("[IDENTITY] Created new identity")

        // Save to Keychain (try first, more secure)
        do {
            try created.saveToKeychain(
                service: keychainService,
                account: keychainAccount
            )
            return created
        } catch {
            sLogger.warning("[IDENTITY] Keychain save failed: \(error.localizedDescription)")
        }

        // Fall back to file storage
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

    /// Save identity to file.
    private static func saveIdentityToFile(_ identity: Identity) -> Bool {
        do {
            let data = try identity.exportPrivateKeys()
            try data.write(to: identityFilePath, options: .atomic)
            return true
        } catch {
            sLogger.warning("[IDENTITY] File save error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Initialization

    /// Create uninitialized AppServices.
    ///
    /// Call `initialize(tcpServerAddress:)` to set up all components.
    public init() {}

    // Note: No deinit needed - stateObserverTask is automatically cancelled
    // when the Task reference is deallocated, and shutdown() should be
    // called explicitly for clean teardown.

    // MARK: - Service Initialization

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
        DiagLog.clear()
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

        // 4. Create persistent LXMF database
        let dbPath = Self.databaseFilePath
        let newDatabase = try LXMFDatabase(path: dbPath)
        self.database = newDatabase

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
            } catch {
                logger.warning("TCP interface failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 9. Register delivery destination with router to receive inbound LXMF messages
        try await newRouter.registerDeliveryDestination(newDestination)

        // Start monitoring interface state for UI updates
        startStateObserver()

        // 10. Initialize propagation node manager
        // IMPORTANT: loadPreferences() MUST run before startListening() so that
        // the saved relay selection (selectedNodeHash, autoSelectEnabled) is restored
        // before the listening task processes path entries and calls autoSelectBestNode().
        // Otherwise the default autoSelectEnabled=true can overwrite the user's manual selection.
        let propManager = PropagationNodeManager(appServices: self)
        self.propagationManager = propManager
        await propManager.loadPreferences()
        propManager.startListening()
        propManager.startPeriodicSync()

        // 11. Initialize auto-announce manager
        let announceManager = AutoAnnounceManager(appServices: self)
        self.autoAnnounceManager = announceManager
        announceManager.start()

        // 12. Start Python RNS backend. The Compat-layer LXMRouter / Transport
        //     are stubs; the real network I/O happens through PythonBridge.
        await startPythonBackend(
            identity: newIdentity,
            identityHashHex: newIdentity.hexHash,
            router: newRouter,
            interfaces: InterfaceRepository().getEnabledInterfaces(),
            displayName: ""
        )

        logger.info("Initialization complete")
    }

    // MARK: - Python backend

    /// Boot the embedded Python RNS stack and hook `LXMRouter.sendHook` so
    /// outbound LXMF sends go through Python. Spawns a Task that drains
    /// Python events and feeds them into Columba's path table / inbound
    /// message handler. Idempotent — does nothing if already started.
    ///
    /// The RNS config file is written from `interfaces` (the user's enabled
    /// `InterfaceEntity` records from `InterfaceRepository`). No host/port
    /// is hardcoded — if `interfaces` is empty the app starts offline and
    /// the user adds an interface in Settings → Manage Interfaces.
    private func startPythonBackend(
        identity: Identity,
        identityHashHex: String,
        router: LXMRouter,
        interfaces: [InterfaceEntity],
        displayName: String
    ) async {
        DiagLog.log("[PY] startPythonBackend entered with \(interfaces.count) interfaces")
        if pythonBackend != nil {
            DiagLog.log("[PY] already started")
            return
        }
        // Cache the start args so restartPythonBackend() can re-invoke
        // this method after the user applies interface changes.
        self.pythonStartIdentity = identity
        self.pythonStartDisplayName = displayName

        let backend = PythonRNSBackend()
        self.pythonBackend = backend

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pyDir = appSupport.appendingPathComponent("Columba/python-\(identityHashHex)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pyDir, withIntermediateDirectories: true)
        let configDir = pyDir.path
        let identityFile = pyDir.appendingPathComponent("identity.bin").path
        DiagLog.log("[PY] configDir=\(configDir)")

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
            DiagLog.log("[PY] wrote config (\(configText.count) bytes, \(interfaces.count) interfaces)")
        } catch {
            DiagLog.log("[PY] config write FAILED: \(error)")
        }

        let identityBytes = try? identity.exportPrivateKeys()
        DiagLog.log("[PY] identityBytes=\(identityBytes?.count ?? -1)")

        do {
            DiagLog.log("[PY] calling backend.start()")
            let info = try await backend.start(
                .init(
                    configDir: configDir,
                    identityPath: identityFile,
                    displayName: displayName,
                    identityBytes: identityBytes
                )
            )
            DiagLog.log("[PY] started identity=\(info.identityHash) destination=\(info.destinationHash)")
            logger.info("Python backend started — identity=\(info.identityHash, privacy: .public) destination=\(info.destinationHash, privacy: .public)")
        } catch {
            DiagLog.log("[PY] start FAILED: \(error)")
            logger.error("Python backend start failed: \(error.localizedDescription, privacy: .public)")
            self.pythonBackend = nil
            return
        }

        // Route outbound LXMF through Python.
        router.sendHook = { [weak backend] message in
            guard let backend else { return }
            let destHex = message.destinationHash.map { String(format: "%02x", $0) }.joined()
            let text = String(data: message.content, encoding: .utf8) ?? ""
            _ = try await backend.sendOpportunistic(destHashHex: destHex, content: text)
        }

        // Drain Python events into Columba's UI plumbing.
        pythonEventTask?.cancel()
        let weakSelf = self
        pythonEventTask = Task { [backend] in
            for await event in backend.events {
                await weakSelf.handlePythonEvent(event)
            }
        }

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

        // Periodic status poll: mirror Python's view of interface state into
        // the Compat TCPInterface stubs so the existing NetworkStatusView /
        // InterfaceManagementScreen show online / offline accurately.
        pythonStatusPollTask?.cancel()
        let entityById = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.id, $0) })
        pythonStatusPollTask = Task { [weak self, backend] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                guard let snapshot = await backend.statusSnapshot() else { continue }
                guard let self else { return }
                await self.applyPythonInterfaceStatus(snapshot: snapshot, entityById: entityById)
            }
        }

        // Listen for test-send deep links (lxma://test-send?to=HEX&content=...).
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestSend"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let to = note.userInfo?["to"] as? String,
                  let content = note.userInfo?["content"] as? String else { return }
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
                    DiagLog.log("[TEST-SEND] no backend")
                    return
                }
                do {
                    let outcome = try await backend.sendOpportunistic(destHashHex: to, content: content)
                    DiagLog.log("[TEST-SEND] outcome=\(outcome)")
                } catch {
                    DiagLog.log("[TEST-SEND] error=\(error)")
                }
            }
        }

        // Listen for test-restart deep link (lxma://test-restart) so
        // smoke tests can exercise the Apply & Restart path without UI.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestRestart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                DiagLog.log("[TEST-RESTART] invoking restartPythonBackend")
                await self.restartPythonBackend()
                DiagLog.log("[TEST-RESTART] done")
            }
        }

        // lxma://test-link-open?to=HEX&aspect=lxst.telephony — exercise the
        // RNS.Link bridge by opening an outbound Link to a destination.
        // Logs the link_id + waits for link_state events to surface via
        // NotificationCenter. For commit-1 smoke testing.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestLinkOpen"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let to = (note.userInfo?["to"] as? String) ?? ""
            let aspect = (note.userInfo?["aspect"] as? String) ?? "lxst.telephony"
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
                    DiagLog.log("[TEST-LINK] no backend")
                    return
                }
                do {
                    let res = try await backend.openLink(destHashHex: to, aspect: aspect)
                    DiagLog.log("[TEST-LINK] open ok=\(res.ok) linkId=\(res.linkId) reason=\(res.reason)")
                } catch {
                    DiagLog.log("[TEST-LINK] open error=\(error)")
                }
            }
        }

        // lxma://test-inbound?from=HEX&content=... — synthesize an inbound
        // event so the privacy filter (block_unknown_senders) can be
        // verified without needing a working peer.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestInbound"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let fromHex = (note.userInfo?["from"] as? String) ?? ""
            let content = (note.userInfo?["content"] as? String) ?? "synthetic"
            guard let from = Data(hexString: fromHex) else {
                DiagLog.log("[TEST-INBOUND] bad hex")
                return
            }
            Task { @MainActor in
                await self.persistInboundFromPython(
                    sourceHash: from,
                    content: content,
                    title: "",
                    timestamp: Date()
                )
            }
        }

        // lxma://test-identity-switch — exercise the multi-identity swap
        // path: create a fresh identity in IdentityManager and call
        // AppServices.switchIdentity. Logs the destination hash before
        // and after so we can verify Python actually rebooted with the
        // new keys.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestIdentitySwitch"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let manager = IdentityManager()
                let before = self.pythonBackend?.localInfo?.destinationHash ?? "nil"
                DiagLog.log("[TEST-IDSWITCH] before destination=\(before)")
                do {
                    let created = try await manager.createIdentity(displayName: "SwitchTarget")
                    let (localId, identity) = try await manager.switchToIdentity(created.identityHash)
                    try await self.switchIdentity(
                        to: identity,
                        identityHash: localId.identityHash,
                        tcpServerAddress: ""
                    )
                    let after = self.pythonBackend?.localInfo?.destinationHash ?? "nil"
                    DiagLog.log("[TEST-IDSWITCH] after destination=\(after) (changed=\(before != after))")
                } catch {
                    DiagLog.log("[TEST-IDSWITCH] error=\(error)")
                }
            }
        }

        // lxma://test-prop-sync?node=HEX — set propagation node, kick a sync,
        // log the outcome.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestPropSync"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let node = (note.userInfo?["node"] as? String) ?? ""
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
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

        // lxma://test-announce?name=... — calls sendAnnounce with the
        // given display name and logs the outcome.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestAnnounce"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let name = (note.userInfo?["name"] as? String) ?? ""
            Task { @MainActor in
                do {
                    try await self.sendAnnounce(displayName: name)
                    DiagLog.log("[TEST-ANNOUNCE] sendAnnounce returned OK")
                } catch {
                    DiagLog.log("[TEST-ANNOUNCE] sendAnnounce failed: \(error)")
                }
            }
        }

        // lxma://test-nomad-fetch?to=HEX&path=/page/index.mu — calls
        // bridge.fetchNomadNetPage and logs the response.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaTestNomadFetch"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let to = note.userInfo?["to"] as? String,
                  let path = note.userInfo?["path"] as? String else { return }
            Task { @MainActor in
                guard let backend = self.pythonBackend else {
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
    }

    /// Look up the matching Python interface for each user `InterfaceEntity`
    /// and update the Compat TCPInterface stub's `state` to reflect the
    /// `online` flag RNS.Transport reports.
    private func applyPythonInterfaceStatus(
        snapshot: PythonBridge.StatusSnapshot,
        entityById: [String: InterfaceEntity]
    ) async {
        // Log every interface Python reports so we can see AutoInterface /
        // RNode / etc. that don't have Compat stubs yet. One-shot per
        // section_name change.
        let snapshotKey = snapshot.interfaces.map { "\($0.sectionName):\($0.online ? 1 : 0)" }.joined(separator: ",")
        if snapshotKey != lastInterfaceSnapshotKey {
            DiagLog.log("[PY] interfaces=\(snapshotKey)")
            lastInterfaceSnapshotKey = snapshotKey
        }
        // The config section name PythonConfigWriter wrote is the matching
        // key — it's stable across the bridge and unique per entity.
        var byEntity: [String: PythonBridge.StatusSnapshot.InterfaceStatus] = [:]
        for status in snapshot.interfaces {
            for (entityId, entity) in entityById {
                let expected = expectedSectionName(for: entity)
                if status.sectionName == expected {
                    byEntity[entityId] = status
                }
            }
        }
        for (entityId, status) in byEntity {
            guard let iface = tcpInterfaces[entityId] else { continue }
            let newState: InterfaceState = status.online ? .connected : .disconnected
            if iface.state != newState {
                DiagLog.log("[PY] iface \(status.sectionName) -> \(newState) (rx=\(status.rxBytes) tx=\(status.txBytes))")
                iface.state = newState
                iface.online = status.online
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
        guard let identity = pythonStartIdentity, let router = self.router else {
            DiagLog.log("[PY] restart skipped — backend was never started")
            return
        }
        DiagLog.log("[PY] restartPythonBackend: stopping current instance")

        pythonEventTask?.cancel()
        pythonEventTask = nil
        pythonStatusPollTask?.cancel()
        pythonStatusPollTask = nil

        if let backend = pythonBackend {
            await backend.stop()
        }
        pythonBackend = nil

        // Drop the Compat TCPInterface stubs so the seed pass below
        // recomputes the set from the latest enabled-interfaces list.
        // (Disabled rows leave their stub behind in stale state otherwise.)
        tcpInterfaces.removeAll()

        let displayName = pythonStartDisplayName
        let fresh = InterfaceRepository().getEnabledInterfaces()
        DiagLog.log("[PY] restartPythonBackend: starting with \(fresh.count) interfaces")
        await startPythonBackend(
            identity: identity,
            identityHashHex: identity.hexHash,
            router: router,
            interfaces: fresh,
            displayName: displayName
        )
    }

    /// Recompute the config-section name PythonConfigWriter would have
    /// written for an entity, so we can match Python interface objects back
    /// to entities by section_name.
    private func expectedSectionName(for entity: InterfaceEntity) -> String {
        let sanitized = entity.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[", with: "_")
            .replacingOccurrences(of: "]", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "#", with: "_")
        return sanitized.isEmpty
            ? entity.id
            : "\(sanitized)-\(entity.id.prefix(6))"
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
    private func persistInboundFromPython(sourceHash: Data, content: String, title: String, timestamp: Date) async {
        guard let database = self.database else {
            DiagLog.log("[PY] persistInbound: no database")
            return
        }
        let repo = MessageRepository(database: database)
        let sourceHashHex = sourceHash.map { String(format: "%02x", $0) }.joined()

        // Privacy: block_unknown_senders drops messages from anyone the
        // user hasn't explicitly favorited (matches the existing
        // IncomingMessageHandler check — favorite is the "this is a
        // real contact, not a random announce hop" signal).
        if UserDefaults.standard.bool(forKey: "block_unknown_senders") {
            let isKnownContact: Bool
            do {
                let conversation = try await database.getConversation(hash: sourceHash)
                isKnownContact = conversation != nil && conversation!.isFavorite != 0
            } catch {
                // Fail open: surface the message if the DB check itself
                // fails (better than silently dropping mail).
                isKnownContact = true
            }
            if !isKnownContact {
                DiagLog.log("[PY] persistInbound BLOCKED source=\(sourceHashHex.prefix(8)) (block_unknown_senders enabled)")
                return
            }
        }

        let displayName = "Peer \(sourceHashHex.prefix(8))"

        do {
            try await repo.ensureConversation(sourceHash, displayName: displayName)

            // Build a synthetic LXMessage so saveMessage can persist it.
            // Hash is the SHA-256 of (sourceHashHex || content || timestamp)
            // truncated to 32 bytes — enough to dedupe; the Python side
            // doesn't expose the canonical message hash through the event.
            let hashInput = (sourceHashHex + content + "\(timestamp.timeIntervalSince1970)").data(using: .utf8) ?? Data()
            let messageHash = Data(SHA256.hash(data: hashInput))

            let message = LXMessage(
                destinationHash: sourceHash,
                sourceIdentity: nil,
                content: content.data(using: .utf8) ?? Data(),
                title: title.data(using: .utf8) ?? Data(),
                fields: nil,
                desiredMethod: .opportunistic
            )
            message.sourceHash = sourceHash
            message.hash = messageHash
            message.incoming = true
            message.timestamp = timestamp.timeIntervalSince1970
            message.state = .received

            try await repo.saveMessage(message)
            DiagLog.log("[PY] persistInbound saved msg=\(messageHash.prefix(4).map { String(format: "%02x", $0) }.joined())")

            // Fire the same notification IncomingMessageHandler would post
            // so ChatsViewModel / MessagingViewModel refresh.
            NotificationCenter.default.post(
                name: IncomingMessageHandler.messageReceivedNotification,
                object: nil,
                userInfo: ["sourceHash": sourceHash]
            )
        } catch {
            DiagLog.log("[PY] persistInbound failed: \(error)")
        }
    }

    private func handlePythonEvent(_ event: PythonBridge.Event) async {
        switch event {
        case .announce(let destHash, let displayName, let aspect, let publicKeysHex, let t):
            DiagLog.log("[PY] announce dest=\(destHash) aspect=\(aspect) name=\"\(displayName)\"")
            guard let data = Data(hexString: destHash) else { return }

            // Insert the announce into the Compat PathTable so the Contacts
            // tab's networkAnnounces list picks it up via the pathUpdates
            // AsyncStream subscription in ContactsViewModel.
            if let pathTable = self.pathTable {
                let publicKeys = Data(hexString: publicKeysHex) ?? Data()
                let entry = PathEntry(
                    destinationHash: data,
                    displayName: displayName,
                    nextHop: data,
                    hopCount: 0,
                    lastSeen: t,
                    publicKeys: publicKeys,
                    interfaceId: "python-rns",
                    appData: nil,
                    expires: t.addingTimeInterval(7 * 86400),
                    timestamp: t,
                    detectedAspect: aspect,
                    isLXMFPropagationNode: aspect == "lxmf.propagation",
                    isLXSTTelephony: aspect == "lxst.telephony",
                    isKnownDestination: true
                )
                await pathTable.insert(entry)
            }

            // Smoke-test auto-send: first time we see a peer's LXMF
            // delivery announce, fire a hello message back through the
            // Python stack. Skipped for non-lxmf.delivery aspects so we
            // don't try to LXMF a nomadnet node.
            if aspect == "lxmf.delivery", smokeTestAutoSentTo.insert(destHash).inserted {
                let backend = pythonBackend
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let backend else { return }
                    let outcome = (try? await backend.sendOpportunistic(
                        destHashHex: destHash,
                        content: "[smoke] hello from \(self.localIdentityHashHex.prefix(8))"
                    )) ?? .other("threw")
                    DiagLog.log("[PY] smoke-send to=\(destHash) outcome=\(outcome)")
                }
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
        case .inbound(let sourceHash, let content, let title, let t):
            DiagLog.log("[PY] inbound source=\(sourceHash) content=\"\(content)\"")
            guard let data = Data(hexString: sourceHash) else { return }
            await persistInboundFromPython(sourceHash: data, content: content, title: title, timestamp: t)
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
            DiagLog.log("[PY] state \(value)")
            logger.info("Python state: \(value, privacy: .public)")
        case .linkState(let linkId, let state, let reason, let inbound, _):
            DiagLog.log("[PY] link \(linkId) state=\(state) inbound=\(inbound)\(reason.isEmpty ? "" : " reason=\(reason)")")
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
                    Task { await self.dispatchInboundLink(linkId: id) }
                } else {
                    Task { await self.dispatchOutboundLinkEstablished(linkId: id) }
                }
            case "closed":
                Task { await self.dispatchLinkClosed(linkId: id, reason: reason) }
            default:
                break  // "establishing" et al — purely informational
            }
        case .linkPacket(let linkId, let data, _):
            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonLinkPacket"),
                object: nil,
                userInfo: ["linkId": linkId, "data": data]
            )
            Task { await self.dispatchLinkPacket(linkId: UInt64(linkId), data: data) }
        case .linkIdentified(let linkId, let identityHashHex, _):
            DiagLog.log("[PY] link \(linkId) identified=\(identityHashHex.prefix(8))")
            NotificationCenter.default.post(
                name: Notification.Name("ColumbaPythonLinkIdentified"),
                object: nil,
                userInfo: ["linkId": linkId, "identityHashHex": identityHashHex]
            )
            Task { await self.dispatchLinkIdentified(linkId: UInt64(linkId), identityHashHex: identityHashHex) }
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
        DiagLog.clear()
        DiagLog.log("[INIT2] Starting with identity: \(identityHash), tcp: \(tcpServerAddress)")

        self.identity = identity
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

        // 4. Create persistent LXMF database (per-identity)
        let dbPath = Self.databaseFilePath(for: identityHash)
        let newDatabase = try LXMFDatabase(path: dbPath)
        self.database = newDatabase

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
            } catch {
                logger.warning("TCP interface failed (non-fatal): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 9. Register delivery destination with router
        try await newRouter.registerDeliveryDestination(newDestination)

        startStateObserver()

        // 10. Initialize propagation node manager
        // IMPORTANT: loadPreferences() MUST run before startListening() — see first overload.
        let propManager = PropagationNodeManager(appServices: self)
        self.propagationManager = propManager
        await propManager.loadPreferences()
        propManager.startListening()
        propManager.startPeriodicSync()

        // 11. Initialize auto-announce manager
        let announceManager = AutoAnnounceManager(appServices: self)
        self.autoAnnounceManager = announceManager
        announceManager.start()

        // Dump all registered destinations and link callbacks for diagnostics
        let regDests = await newTransport.registeredDestinationHashes()
        let regCallbacks = await newTransport.registeredLinkCallbackHashes()
        DiagLog.log("[INIT2] Registered destinations: \(regDests)")
        DiagLog.log("[INIT2] Registered link callbacks: \(regCallbacks)")
        // Apply persisted transport mode setting
        if SharedDefaults.suite.bool(forKey: "transport_enabled") {
            await newTransport.setTransportEnabled(true, identity: identity)
            DiagLog.log("[INIT2] Transport mode enabled")
        }

        #if ENABLE_NETWORK_EXTENSION
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

        // 13. Load tunnel manager
        let tunnel = TunnelManager()
        self.tunnelManager = tunnel

        // Wire tunnel state -> per-interface tunnel-mode coordination.
        // When the VPN extension reports `.connected`, switch each
        // TCPInterface / AutoInterface into tunnel mode so its
        // outbound traffic flows through the extension's authoritative
        // socket instead of through a duplicate local NWConnection.
        // When the extension goes back to `.disconnected`, restore the
        // local NWConnection-managed path. The closure is invoked on
        // the main actor by TunnelManager.
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
        #endif

        // Start Python RNS backend on the multi-identity path too.
        await startPythonBackend(
            identity: identity,
            identityHashHex: identityHash,
            router: newRouter,
            interfaces: InterfaceRepository().getEnabledInterfaces(),
            displayName: ""
        )

        DiagLog.log("[INIT2] Initialization complete (identity: \(identityHash))")
    }

    #if ENABLE_NETWORK_EXTENSION
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

        if active {
            for (_, iface) in tcpInterfaces {
                await iface.beginTunnelMode { [weak tunnel] frame in
                    await tunnel?.sendFrame(frame, interfaceTag: FrameInterfaceTag.tcp.rawValue)
                }
            }
            if let auto = autoInterface {
                await auto.beginTunnelMode { [weak tunnel] frame in
                    await tunnel?.sendFrame(frame, interfaceTag: FrameInterfaceTag.auto.rawValue)
                }
            }
            DiagLog.log("[TUNNEL] enabled tunnel mode on \(self.tcpInterfaces.count) TCP + \(self.autoInterface != nil ? 1 : 0) Auto interface(s)")
        } else {
            for (_, iface) in tcpInterfaces {
                await iface.endTunnelMode()
            }
            if let auto = autoInterface {
                await auto.endTunnelMode()
            }
            DiagLog.log("[TUNNEL] disabled tunnel mode; interfaces resuming local connections")
        }
    }
    #endif

    /// Switch to a different identity, tearing down and re-initializing the full stack.
    ///
    /// - Parameters:
    ///   - newIdentity: The identity to switch to (already loaded from Keychain)
    ///   - identityHash: Hex hash of the new identity
    ///   - tcpServerAddress: TCP server address to reconnect to
    public func switchIdentity(to newIdentity: Identity, identityHash: String, tcpServerAddress: String) async throws {
        logger.info("Switching identity to: \(identityHash)")

        // Tear down current stack
        await shutdown()

        // NOTE: Path table is NOT cleared here — path entries (announce routes)
        // are identity-agnostic and remain valid across identity switches.
        // Only reconnect() clears paths (different network = stale routes).

        // Small delay to ensure clean shutdown
        try? await Task.sleep(for: .milliseconds(200))

        // Re-initialize with new identity
        try await initialize(identity: newIdentity, identityHash: identityHash, tcpServerAddress: tcpServerAddress)

        logger.info("Identity switch complete: \(identityHash)")
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

                // Auto-announce on connect (outside the MainActor.run to avoid blocking UI)
                if shouldAnnounce {
                    try? await Task.sleep(for: .seconds(1))
                    _ = await MainActor.run {
                        Task {
                            await self.autoAnnounce()
                            self.autoAnnounceManager?.resetTimer()
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
        // Stop existing auto interface if any
        await stopAutoInterface()

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
    }

    /// Stop the AutoInterface.
    public func stopAutoInterface() async {
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
    public func startBLEInterface() async throws {
        logger.info("[BLE_DIAG] startBLEInterface() called")

        // Stop existing BLE interface if running
        if bleInterface != nil {
            await stopBLEInterface()
            // Give CoreBluetooth time to release the old CBCentralManager/CBPeripheralManager
            // before creating new ones. Without this, the new managers can see "resetting" state.
            try? await Task.sleep(for: .milliseconds(500))
        }

        // Ensure base stack exists
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

    /// Stop the BLE interface.
    public func stopBLEInterface() async {
        guard let ble = bleInterface else { return }
        await ble.disconnect()
        if let transport = transport {
            await transport.removeInterface(id: ble.id)
        }
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
        await stopMPCInterface()

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
    /// Creates an RNodeInterface, configures the radio, and registers it with
    /// the transport layer (which calls connect()). If the base stack hasn't
    /// been initialized yet, initializes it first.
    ///
    /// - Parameters:
    ///   - config: RNode radio configuration (device name, frequency, etc.)
    ///   - name: Display name for the interface
    public func startRNodeInterface(config rnodeConfig: RNodeConfig, name: String) async throws {
        // Stop existing RNode interface if running
        await stopRNodeInterface()

        // Ensure base stack exists
        if transport == nil {
            try await initializeBaseStack()
        }

        guard let transport = transport else {
            throw AppServicesError.transportNotConnected
        }

        let transportConfig = InterfaceConfig(
            id: "rnode0",
            name: name,
            type: .rnode,
            enabled: true,
            mode: .full,
            host: rnodeConfig.deviceName,  // BLE device name in "host" field
            port: 0
        )

        let newRNodeInterface = try RNodeInterface(config: transportConfig)

        // Configure radio BEFORE connecting (critical ordering)
        let radioConfig = rnodeConfig.toRadioConfig()
        try await newRNodeInterface.configureRadio(radioConfig)

        self.rnodeInterface = newRNodeInterface

        // Register with transport — this calls connect() which starts BLE scan
        try await transport.addInterface(newRNodeInterface)
        logger.info("RNodeInterface started: \(name)")
    }

    /// Stop the RNode interface.
    public func stopRNodeInterface() async {
        guard let rnode = rnodeInterface else { return }
        await rnode.disconnect()
        if let transport = transport {
            await transport.removeInterface(id: rnode.id)
        }
        rnodeInterface = nil
        logger.info("RNodeInterface stopped")
    }

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

        // 4. Database
        if database == nil {
            let dbPath = Self.databaseFilePath
            let newDatabase = try LXMFDatabase(path: dbPath)
            self.database = newDatabase
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
    public func getBLEConnectionInfos() async -> [BLEConnectionInfo] {
        guard let ble = bleInterface else { return [] }
        return await ble.getConnectionInfos()
    }

    /// Disconnect a specific BLE peer.
    public func disconnectBLEPeer(identityHex: String) async {
        guard let ble = bleInterface else { return }
        await ble.disconnectPeer(identityHex: identityHex)
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
        logger.info("Shutting down AppServices")

        stateObserverTask?.cancel()
        stateObserverTask = nil

        // Stop Python event drain and tear down the Python RNS stack
        pythonEventTask?.cancel()
        pythonEventTask = nil
        pythonStatusPollTask?.cancel()
        pythonStatusPollTask = nil
        if let backend = pythonBackend {
            await backend.stop()
            pythonBackend = nil
        }

        // Stop auto-announce manager
        autoAnnounceManager?.stop()

        // Stop propagation manager
        propagationManager?.stopListening()
        propagationManager?.stopPeriodicSync()

        // Shutdown router first (stops processing loop)
        await router?.shutdown()

        // Disconnect all TCP interfaces
        await stopTCPInterface()

        // Stop RNode interface
        await stopRNodeInterface()

        // Stop BLE interface
        #if canImport(CoreBluetooth)
        await stopBLEInterface()
        #endif

        // Stop auto interface
        await stopAutoInterface()

        isConnected = false
        logger.info("AppServices shutdown complete")
    }

    /// Connect a TCP interface by entity ID, replacing any existing one with the same ID.
    ///
    /// Multiple concurrent TCP interfaces are supported — each entity ID is independent.
    public func connectTCPInterface(entityId: String, host: String, port: UInt16) async throws {
        // Stop any existing interface with this entity ID
        if let existing = tcpInterfaces[entityId] {
            await existing.disconnect()
            await transport?.removeInterface(id: entityId)
            tcpInterfaces.removeValue(forKey: entityId)
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
        try await transport.addInterface(newInterface)

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
    }

    /// Stop a specific TCP interface by entity ID.
    public func stopTCPInterface(entityId: String) async {
        guard let interface = tcpInterfaces[entityId] else { return }
        await interface.disconnect()
        await transport?.removeInterface(id: entityId)
        tcpInterfaces.removeValue(forKey: entityId)
    }

    /// Stop all TCP interfaces.
    public func stopTCPInterface() async {
        for (entityId, interface) in tcpInterfaces {
            await interface.disconnect()
            await transport?.removeInterface(id: entityId)
        }
        tcpInterfaces.removeAll()
        isConnected = false
    }

    /// Reconnect only the TCP interface without tearing down BLE/Auto/RNode.
    /// Uses the legacy "tcp-server" entity ID for backward compatibility.
    public func reconnectTCPOnly(host: String, port: UInt16) async throws {
        try await connectTCPInterface(entityId: "tcp-server", host: host, port: port)
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
        logger.info("Reconnecting to new TCP server: \(tcpServerAddress)")

        // 1. Shutdown existing connection
        await shutdown()

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
        try await newTransport.addInterface(newInterface)

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
        guard let backend = pythonBackend else {
            throw AppServicesError.transportNotConnected
        }
        let ok = try await backend.announce(displayName: displayName)
        if !ok {
            throw AppServicesError.transportNotConnected
        }
        DiagLog.log("[ANNOUNCE] sent via Python (name=\"\(displayName)\")")
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

        // Telephony announce removed in Phase 0 of the Python RNS migration.

        if let firstError { throw firstError }
    }

    /// Wire transport callbacks that need app-layer context.
    private func configureTransportCallbacks(_ transport: ReticulumTransport) async {
        await transport.setOnInterfaceAdded { [weak self] _ in
            guard let self else { return }
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
        guard let backend = self.pythonBackend else {
            throw AppServicesError.transportNotConnected
        }
        let destHex = destination.hash.toHex()
        let aspect = ([destination.appName] + destination.aspects).joined(separator: ".")
        let result = try await backend.openLink(destHashHex: destHex, aspect: aspect)
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
        activeLinksByLinkId[linkIdRaw] = link
        DiagLog.log("[TEL_BRIDGE] opened outbound link \(linkIdRaw) → \(destHex.prefix(8))")
        return link
    }

    /// Map a Python link_state(closed, reason=...) string to the
    /// TeardownReason enum lxst-swift's Telephone understands.
    private func teardownReason(from raw: String) -> TeardownReason {
        switch raw {
        case "destination_closed", "remote_closed": return .destinationClosed
        case "initiator_closed", "local_closed":    return .initiatorClosed
        case "timeout":                              return .timeout
        default:                                     return .networkFailure
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
        if let backend = self.pythonBackend {
            let backendRef = backend
            link.sendBytesHook = { data in
                _ = try? await backendRef.linkSend(linkId: Int(linkId), data: data)
            }
        }
        activeLinksByLinkId[linkId] = link
        let callbacks = Array(destinationLinkCallbacks.values)

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
    /// onInterfaceAdded from both the peer callback and the state-change
    /// delegate, so this prevents redundant announces.
    private func autoAnnounce() async {
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
        }
    }
}
