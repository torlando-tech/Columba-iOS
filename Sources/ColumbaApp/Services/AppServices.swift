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
import LXMFSwift
import ReticulumSwift
import os.log

/// Central LXMF service layer for the SwiftUI application.
///
/// AppServices initializes and holds all components needed for LXMF messaging:
/// - **Identity**: Local Reticulum identity for signing/encryption
/// - **LXMRouter**: LXMF message router for sending/receiving
/// - **ReticuLumTransport**: Transport layer with path routing
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
    public private(set) var transport: ReticuLumTransport?

    /// Path table for route lookups.
    public private(set) var pathTable: PathTable?

    /// TCP interface to server.
    public private(set) var tcpInterface: TCPInterface?

    /// Auto discovery interface for LAN peer discovery.
    public private(set) var autoInterface: AutoInterface?

    /// LXMF delivery destination for receiving messages.
    public private(set) var deliveryDestination: Destination?

    /// LXMF database for message persistence.
    public private(set) var database: LXMFDatabase?

    /// Propagation node manager for relay discovery and sync.
    public private(set) var propagationManager: PropagationNodeManager?

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

    /// Hex string of local identity hash for display.
    public var localIdentityHashHex: String {
        localIdentityHash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Internal State

    /// Logger for debugging service initialization.
    private let logger = Logger(subsystem: "com.columba.app", category: "AppServices")


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

    /// File path for LXMF database persistence.
    private static var databaseFilePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let columbaDir = appSupport.appendingPathComponent("Columba", isDirectory: true)
        // Create directory if needed
        try? FileManager.default.createDirectory(at: columbaDir, withIntermediateDirectories: true)
        return columbaDir.appendingPathComponent("lxmf.db").path
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
                print("[IDENTITY] ✓ Loaded from Keychain: \(stored.hexHash)")
                return stored
            }
        } catch {
            print("[IDENTITY] Keychain load error: \(error)")
        }

        // Try file-based storage (fallback)
        if let stored = loadIdentityFromFile() {
            print("[IDENTITY] ✓ Loaded from file: \(stored.hexHash)")
            return stored
        }

        // Create new identity
        let created = Identity()
        print("[IDENTITY] + Created new identity: \(created.hexHash)")

        // Save to Keychain (try first, more secure)
        do {
            try created.saveToKeychain(
                service: keychainService,
                account: keychainAccount
            )
            print("[IDENTITY] ✓ Saved to Keychain")
            return created
        } catch {
            print("[IDENTITY] Keychain save failed: \(error)")
        }

        // Fall back to file storage
        if saveIdentityToFile(created) {
            print("[IDENTITY] ✓ Saved to file: \(identityFilePath.path)")
        } else {
            print("[IDENTITY] ⚠ Failed to save identity - will be ephemeral")
        }

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
            print("[IDENTITY] File load error: \(error)")
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
            print("[IDENTITY] File save error: \(error)")
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
    /// 3. Creates ReticuLumTransport with the PathTable
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
        logger.info("Starting initialize with TCP server: \(tcpServerAddress, privacy: .public)")

        // 1. Load identity from persistent storage (try Keychain first, then file)
        let newIdentity: Identity = Self.loadOrCreateIdentity()
        self.identity = newIdentity

        // 2. Create path table for routing with persistence
        let pathDbPath = Self.pathTableFilePath
        let newPathTable = try PathTable(databasePath: pathDbPath)
        self.pathTable = newPathTable

        // 3. Create transport with path table
        let newTransport = ReticuLumTransport(pathTable: newPathTable)
        self.transport = newTransport

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

        // 7. Set transport on router for message delivery (before interfaces, so
        //    router is ready to receive packets as soon as any interface connects)
        await newRouter.setTransport(newTransport)

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
                self.tcpInterface = newInterface
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
        let propManager = PropagationNodeManager(appServices: self)
        self.propagationManager = propManager
        propManager.startListening()
        await propManager.loadPreferences()
        propManager.startPeriodicSync()

        logger.info("Initialization complete")
    }

    // MARK: - State Observation

    /// Start observing interface state for UI updates.
    private func startStateObserver() {
        stateObserverTask?.cancel()
        stateObserverTask = Task { [weak self] in
            guard let self = self else { return }

            // Track the last error we reported to avoid spamming logs
            var lastReportedError: String?

            // Poll interface state periodically
            // (TCPInterface doesn't expose AsyncStream for state changes)
            while !Task.isCancelled {
                await self.updateConnectionState()

                // Check for error info from the interface's underlying transport
                if let interface = await self.tcpInterface {
                    let state = await interface.state
                    if case .reconnecting = state {
                        // Get the last error description from the transport
                        let errorDesc = await interface.lastErrorDescription
                        if let desc = errorDesc, desc != lastReportedError {
                            lastReportedError = desc
                            await MainActor.run {
                                self.connectionError = desc
                            }
                        }
                    } else if state == .connected {
                        if lastReportedError != nil {
                            lastReportedError = nil
                            await MainActor.run {
                                self.connectionError = nil
                            }
                        }
                    }
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Update connection state from interface.
    private func updateConnectionState() async {
        guard let interface = tcpInterface else {
            if isConnected {
                isConnected = false
                connectionError = nil
                isReconnecting = false
            }
            return
        }

        let state = await interface.state
        switch state {
        case .connected:
            if !isConnected {
                isConnected = true
                connectionError = nil
                isReconnecting = false
                logger.info("Connection state changed: connected")

                // Auto-announce LXMF delivery destination so peers can reach us
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await autoAnnounce()
                }
            }
        case .reconnecting(let attempt):
            if isConnected || !isReconnecting {
                isConnected = false
                isReconnecting = true
                logger.info("Connection state changed: reconnecting (attempt \(attempt))")
            }
        case .connecting:
            if isConnected {
                isConnected = false
                logger.info("Connection state changed: connecting")
            }
        case .disconnected:
            if isConnected || isReconnecting {
                isConnected = false
                isReconnecting = false
                logger.info("Connection state changed: disconnected")
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

    /// Initialize the base stack (identity, transport, router) without a TCP interface.
    ///
    /// Used when starting only AutoInterface without a TCP server.
    private func initializeBaseStack() async throws {
        // 1. Identity
        if identity == nil {
            let newIdentity = Self.loadOrCreateIdentity()
            self.identity = newIdentity
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
            let newTransport = ReticuLumTransport(pathTable: pt)
            self.transport = newTransport
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
    }

    // MARK: - Shutdown

    /// Shutdown all services gracefully.
    ///
    /// Disconnects the TCP interface, shuts down the router, and cleans up resources.
    public func shutdown() async {
        logger.info("Shutting down AppServices")

        stateObserverTask?.cancel()
        stateObserverTask = nil

        // Stop propagation manager
        propagationManager?.stopListening()
        propagationManager?.stopPeriodicSync()

        // Shutdown router first (stops processing loop)
        await router?.shutdown()

        // Disconnect TCP interface
        await tcpInterface?.disconnect()

        // Stop auto interface
        await stopAutoInterface()

        // Remove interface from transport
        if let transport = transport {
            await transport.removeInterface(id: "tcp-server")
        }

        isConnected = false
        logger.info("AppServices shutdown complete")
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
        let newTransport = ReticuLumTransport(pathTable: newPathTable)
        self.transport = newTransport

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
        self.tcpInterface = newInterface

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
    /// - Parameter displayName: Display name to broadcast (e.g., "Tyler's Mac")
    /// - Throws: AppServicesError if transport or destination not initialized
    public func sendAnnounce(displayName: String) async throws {
        logger.info("Sending announce with display name: \(displayName)")

        guard let transport = transport else {
            throw AppServicesError.transportNotConnected
        }

        guard let destination = deliveryDestination else {
            throw AppServicesError.identityNotInitialized
        }

        // Set the display name as app data on the destination
        destination.appData = displayName.data(using: .utf8)

        // Create and build the announce packet
        let announce = Announce(destination: destination)
        let packet = try announce.buildPacket()

        // Send the announce via transport
        try await transport.send(packet: packet)

        logger.info("Announce sent successfully for destination: \(destination.hexHash)")
    }

    /// Auto-announce on interface connect using the stored display name.
    private func autoAnnounce() async {
        let displayName = await SettingsRepository().getDisplayName()
        do {
            try await sendAnnounce(displayName: displayName)
            logger.info("Auto-announce completed on interface connect")
        } catch {
            logger.warning("Auto-announce failed: \(error.localizedDescription)")
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
