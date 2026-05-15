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

    /// Fetch the last disconnect error from the underlying VPN
    /// connection, if any. `startVPNTunnel()` is fire-and-forget —
    /// when the tunnel fails to connect (airplane mode, routing
    /// failure, extension crash) the launch call returns successfully
    /// and the failure is reported asynchronously. The Settings toggle
    /// uses this after a polling timeout to surface a meaningful
    /// reason instead of silently bouncing.
    ///
    /// `fetchLastDisconnectError` is iOS 16+; we already require
    /// iOS 17.
    public func lastFailureReason() async -> String? {
        guard let connection = manager?.connection else { return nil }
        return await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                continuation.resume(returning: (error as NSError?)?.localizedDescription)
            }
        }
    }

    /// Called whenever the tunnel's VPN status changes.
    ///
    /// `AppServices` uses this to coordinate transitioning each
    /// `TCPInterface` / `AutoInterface` into and out of tunnel-mode
    /// (where outbound is routed via the extension instead of a
    /// duplicate local NWConnection).
    public var onStatusChange: (@Sendable (NEVPNStatus) -> Void)?

    /// Called once just before `startVPNTunnel()` fires, so the app
    /// can put its interfaces in tunnel mode (release UDP sockets,
    /// install the outbound hook) before the extension starts and
    /// tries to bind the same ports. Without this, the extension's
    /// `NWMulticastGroup` and `NWListener` race the app for the
    /// AutoInterface multicast / data ports and fail with
    /// `EADDRINUSE`.
    public var onWillStart: (@Sendable () async -> Void)?

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

            // Observe status changes. Bind to `object: nil` (all VPN
            // status notifications) so a later `install()` / fresh
            // profile after a delete-and-re-add doesn't leave the
            // observer stuck on the old connection — we re-resolve
            // `self.manager?.connection.status` inside the callback,
            // which always reflects whichever manager we currently
            // hold.
            NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
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

        // On-demand always-connect: lets iOS keep the tunnel up
        // across wake/sleep, network changes, and restart it after
        // the system tears it down under memory pressure. Without
        // this the extension stays up only until something kills
        // it and never recovers on its own.
        mgr.isOnDemandEnabled = true
        mgr.onDemandRules = [NEOnDemandRuleConnect()]

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()

        manager = mgr
        isEnabled = true
        status = mgr.connection.status
        logger.info("Tunnel config installed")
    }

    /// Start the tunnel extension.
    public func start() async throws {
        // Refresh from system preferences in case the user deleted
        // the VPN profile from iOS Settings while we held a cached
        // reference. Without this, `startVPNTunnel()` would fail with
        // `NEVPNErrorConfigurationInvalid` (error 1) on the stale
        // manager and the toggle would never recover.
        if let managers = try? await NETunnelProviderManager.loadAllFromPreferences() {
            if let existing = managers.first {
                manager = existing
            } else {
                manager = nil
            }
        }

        guard let manager else {
            try await install()
            try await start()
            return
        }

        // Reflect user intent on the observable up-front so re-enable
        // paths (where `disable()` previously cleared `self.isEnabled`)
        // don't leave the published value stale while the profile is
        // being re-saved.
        isEnabled = true

        // Re-assert profile flags — handles two cases:
        //  1. Migration: profiles installed before on-demand was
        //     added need the rules applied on the next start.
        //  2. Re-enable after explicit disable(): that path clears
        //     isEnabled AND isOnDemandEnabled; both must come back.
        var needsSave = false
        if !manager.isEnabled {
            manager.isEnabled = true
            needsSave = true
        }
        if !manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = true
            needsSave = true
        }
        if manager.onDemandRules?.isEmpty ?? true {
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            needsSave = true
        }
        if needsSave {
            try await manager.saveToPreferences()
        }

        // Bail before firing `startVPNTunnel()` if our caller's Task
        // was cancelled during the awaited install/save above —
        // otherwise a rapid OFF tap during a still-running ON would
        // still bring the tunnel up despite the user's last intent.
        try Task.checkCancellation()

        // Release any per-interface UDP sockets the app holds before
        // the extension launches and tries to bind the same ports.
        // The hook is awaited so we don't return from `start()`
        // until interfaces are fully in tunnel mode.
        if let willStart = onWillStart {
            await willStart()
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
        // Reflect user intent on the observable before any throwing
        // call so observers see "off" even if `saveToPreferences()`
        // fails. Without this, a thrown save leaves `self.isEnabled`
        // stuck at `true` while the profile is partially mutated.
        isEnabled = false
        manager.connection.stopVPNTunnel()
        var needsSave = false
        if manager.isEnabled {
            manager.isEnabled = false
            needsSave = true
        }
        // Clear on-demand too — otherwise iOS auto-resumes the
        // tunnel after `stopVPNTunnel()` per the always-connect
        // rule and the toggle silently bounces back on.
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            needsSave = true
        }
        if needsSave {
            try await manager.saveToPreferences()
        }
        logger.info("Tunnel disabled")
    }

    /// Tell the extension to terminate its current session via
    /// `cancelTunnelWithError`, forcing iOS to spawn a fresh
    /// extension process the next time the tunnel starts. Used by
    /// `tools/auto-test/run_test.sh` to reload the extension binary
    /// after a build without the user manually deleting and
    /// re-adding the VPN profile in iOS Settings.
    public func debugReloadExtension() async {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return
        }
        let message = Data([0xFE]) // DEBUG_RELOAD_COMMAND in extension
        do {
            try session.sendProviderMessage(message) { _ in }
            logger.info("Debug reload requested")
        } catch {
            logger.error("Debug reload failed: \(error)")
        }
    }

    /// Send a raw frame to the extension for transmission.
    ///
    /// The extension will route this to the appropriate NWConnection
    /// based on the interface tag and entity ID.
    ///
    /// Wire format (matches `PacketTunnelProvider.handleAppMessage`):
    /// `[1B tag][1B idLen][N idBytes][M frameData]`
    ///
    /// - Parameters:
    ///   - data: Raw frame data (already HDLC-framed for TCP)
    ///   - interfaceTag: Which interface to send on (TCP=0x01, Auto=0x02)
    ///   - entityId: Identifier of the source `TCPInterface` so the
    ///     extension picks the right `NWConnection` when multiple TCP
    ///     interfaces are tunneled simultaneously. Empty string keeps
    ///     the legacy behaviour where the extension routes to its sole
    ///     connection (used by Auto and by single-TCP fallbacks).
    public func sendFrame(_ data: Data, interfaceTag: UInt8, entityId: String = "") async {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return
        }

        let idBytes = Array(entityId.utf8.prefix(255))
        var message = Data()
        message.reserveCapacity(2 + idBytes.count + data.count)
        message.append(interfaceTag)
        message.append(UInt8(idBytes.count))
        if !idBytes.isEmpty {
            message.append(contentsOf: idBytes)
        }
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
