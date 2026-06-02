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
import RNSAPI
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

        // On-demand: relaunch the tunnel automatically after iOS terminates it
        // (jetsam / reboot / user toggle) so background delivery resumes without
        // the app being foregrounded — the NE can't wake itself, so a connect rule
        // keeps it up whenever a network path exists (the deliver-while-locked
        // posture; see Track C2/C4). NEOnDemandRuleConnect with no interface match
        // applies on every interface (WiFi + cellular).
        mgr.isOnDemandEnabled = true
        mgr.onDemandRules = [NEOnDemandRuleConnect()]

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()

        manager = mgr
        isEnabled = true
        status = mgr.connection.status
        logger.info("Tunnel config installed (on-demand connect enabled)")
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

    /// Stop the tunnel extension.
    public func stop() {
        manager?.connection.stopVPNTunnel()
        logger.info("Tunnel stopped")
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
        // Bridge diagnostic: report the frame and whether a live NE session
        // exists. `session=NIL` here means the frame is DROPPED below (no
        // NETunnelProviderSession to forward it on). DiagLog is visible from
        // this module (ColumbaApp), so mirror to it directly. NO-PII: tag +
        // byte length only. Use the same `as?` the guard uses so the logged
        // state and the drop decision can't disagree.
        let session = manager?.connection as? NETunnelProviderSession
        DiagLog.log("[BRIDGE-OUT] sendFrame tag=\(interfaceTag) len=\(data.count) session=\(session != nil ? "yes" : "NIL")")
        guard let session else {
            DiagLog.log("[BRIDGE-OUT] sendFrame DROPPED: no NETunnelProviderSession")
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

    /// Track A5b — Model B IPC transport for `ProxyRnsBackend`.
    ///
    /// Send a `ProxyRequest` envelope (already magic+version-framed by
    /// `ProxyIPC.encodeRequest`) to the extension and await its `ProxyResponse`
    /// bytes, bridging `NETunnelProviderSession.sendProviderMessage`'s
    /// completion-handler API into `async`. Returns the raw response `Data` the NE
    /// hands back (an encoded `ProxyResponse`), or `nil` when there's no live
    /// session or the send throws — the proxy maps `nil` onto an IPC-failure.
    ///
    /// `BackendFactory.make(proxySend:)` injects this as the proxy's `send`
    /// closure when Model B is on (currently never — `BackendPreference.modelB`
    /// defaults `false`), so this primitive is present + testable but inert until
    /// A5c wires it live.
    public func proxySend(_ data: Data) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                self.logger.error("proxySend failed: \(error)")
                continuation.resume(returning: nil)
            }
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
