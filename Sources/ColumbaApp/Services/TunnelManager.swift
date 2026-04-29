//
//  TunnelManager.swift
//  ColumbaApp
//
//  Manages the Network Extension (NEPacketTunnelProvider) lifecycle.
//  Handles loading, starting, stopping, and sending messages to the extension.
//
//  Requires paid Apple Developer account. Enable by adding ENABLE_NETWORK_EXTENSION
//  to Swift Active Compilation Conditions in the ColumbaApp target build settings.
//

#if ENABLE_NETWORK_EXTENSION

import Foundation
import NetworkExtension
import os.log

/// Manages the Columba Network Extension tunnel.
///
/// The extension keeps TCP and AutoInterface NWConnections alive while the
/// app is backgrounded. This manager handles the VPN configuration profile
/// and IPC with the running extension.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class TunnelManager: @unchecked Sendable {

    // MARK: - Properties

    /// Current extension status
    public private(set) var status: NEVPNStatus = .disconnected

    /// Whether the extension is enabled in settings
    public private(set) var isEnabled = false

    /// The loaded tunnel provider manager
    private var manager: NETunnelProviderManager?

    /// Called whenever the tunnel's VPN status changes.
    ///
    /// `AppServices` uses this to coordinate transitioning each
    /// `TCPInterface` / `AutoInterface` into and out of tunnel-mode
    /// (where outbound is routed via the extension instead of a
    /// duplicate local NWConnection).
    public var onStatusChange: (@Sendable (NEVPNStatus) -> Void)?

    private let logger = Logger(subsystem: "network.columba.Columba", category: "TunnelManager")

    // MARK: - Lifecycle

    /// Load the existing VPN configuration or create a new one.
    public func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let existing = managers.first {
                manager = existing
                isEnabled = existing.isEnabled
                status = existing.connection.status
                logger.info("Loaded existing tunnel config, enabled=\(existing.isEnabled)")
            } else {
                logger.info("No tunnel config found")
            }

            // Observe status changes
            NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: manager?.connection,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    let newStatus = self.manager?.connection.status ?? .disconnected
                    self.status = newStatus
                    self.onStatusChange?(newStatus)
                }
            }

            // Fire `onStatusChange` once for the post-load state. iOS
            // keeps the extension alive across app relaunches, so the
            // tunnel can already be `.connected` by the time the app
            // cold-starts and wires its callback. Without this initial
            // fire, observers (like AppServices' tunnel-mode
            // coordinator) would never learn the tunnel is up and the
            // app's TCPInterface would race the extension's socket —
            // exactly the split-horizon bug Phase 2 is meant to
            // prevent.
            if let cb = onStatusChange {
                cb(status)
            }
        } catch {
            logger.error("Failed to load tunnel config: \(error)")
        }
    }

    /// Install or update the VPN configuration profile.
    public func install() async throws {
        let mgr: NETunnelProviderManager
        if let existing = manager {
            mgr = existing
        } else {
            mgr = NETunnelProviderManager()
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "network.columba.Columba.tunnel"
        proto.serverAddress = "Columba Transport"

        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "Columba Background Transport"
        mgr.isEnabled = true

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()

        manager = mgr
        isEnabled = true
        status = mgr.connection.status
        logger.info("Tunnel config installed")
    }

    /// Start the tunnel extension.
    public func start() async throws {
        guard let manager else {
            try await install()
            try await start()
            return
        }

        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
        }

        try manager.connection.startVPNTunnel()
        logger.info("Tunnel started")
    }

    /// Disable the tunnel: stop the VPN session and clear `isEnabled`
    /// in the saved profile so iOS releases routing fully.
    ///
    /// Calling `stopVPNTunnel()` alone leaves `manager.isEnabled == true`,
    /// which iOS treats as "the tunnel can be auto-resumed" and can
    /// keep parts of the routing table installed. That is what caused
    /// the previous "toggle off but TCP stays broken" report — the
    /// profile was still partially live.
    ///
    /// Use `uninstall()` instead if the user wants to remove the
    /// VPN profile from iOS Settings entirely.
    public func disable() async throws {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        if manager.isEnabled {
            manager.isEnabled = false
            try await manager.saveToPreferences()
        }
        isEnabled = false
        logger.info("Tunnel disabled")
    }

    /// Send a raw frame to the extension for transmission.
    ///
    /// The extension will route this to the appropriate NWConnection
    /// based on the interface tag.
    ///
    /// - Parameters:
    ///   - data: Raw frame data (already HDLC-framed for TCP)
    ///   - interfaceTag: Which interface to send on (TCP=0x01, Auto=0x02)
    public func sendFrame(_ data: Data, interfaceTag: UInt8) async {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return
        }

        var message = Data([interfaceTag])
        message.append(data)

        do {
            try session.sendProviderMessage(message) { _ in }
        } catch {
            logger.error("sendProviderMessage failed: \(error)")
        }
    }

    /// Whether the extension is currently running.
    public var isRunning: Bool {
        status == .connected
    }

    /// Remove the VPN configuration entirely.
    public func uninstall() async throws {
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
        isEnabled = false
        status = .disconnected
        logger.info("Tunnel config removed")
    }
}

#endif
