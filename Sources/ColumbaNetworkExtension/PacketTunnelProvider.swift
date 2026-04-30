//
//  PacketTunnelProvider.swift
//  ColumbaNetworkExtension
//
//  Minimal NEPacketTunnelProvider that keeps TCP and AutoInterface NWConnections
//  alive while the main app is backgrounded. No Reticulum protocol knowledge,
//  no crypto, no LXMF parsing — just raw frame forwarding via a shared queue file.
//
//  Inbound: TCP/Auto data → HDLC deframe (TCP only) → SharedFrameQueue → Darwin notif
//  Outbound: App sends via sendProviderMessage → extension sends on NWConnection
//

import Foundation
import Network
import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Constants

    /// Notification posted to the app when inbound frames are queued.
    private static let packetReadyNotification = SharedDefaultsConstants.packetReadyNotificationName
    /// Notification observed when the app writes interface-config
    /// changes; triggers a reload so unrelated interfaces stay
    /// connected while a single relay is added/removed/edited.
    private static let configChangedNotification = SharedDefaultsConstants.configChangedNotificationName
    private static let interfacesKey = SharedDefaultsConstants.interfacesKey

    // MARK: - Properties

    private lazy var frameQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier)
    /// Drives the extension's AutoInterface — peer discovery
    /// (`ff12:0:…` multicast derived from the group id) plus
    /// per-peer unicast data on the data port. Replaces the
    /// previous single-`NWConnectionGroup` path that hard-coded
    /// `ff02::1` and never delivered data to peers.
    private lazy var autoBridge = ExtensionAutoBridge(
        frameQueue: frameQueue,
        postNotif: { [weak self] in self?.postDarwinNotification() }
    )

    /// Per-entity TCP `NWConnection`s. Multiple TCP relays can be
    /// tunneled simultaneously — each `InterfaceEntity` from the app
    /// gets its own connection and its own HDLC receive buffer here.
    /// Mutated only on `configQueue` to avoid races with Darwin
    /// notification callbacks arriving on a Mach-port thread.
    private var tcpConnections: [String: NWConnection] = [:]

    /// Currently-applied TCP endpoints, keyed by entity id. Used to
    /// diff config changes so an unrelated entry doesn't get its
    /// connection torn down when the user adds or edits a different
    /// one.
    private var currentTCPs: [String: (host: String, port: UInt16)] = [:]

    /// Per-connection HDLC receive buffer. Each TCP relay has its own
    /// stream so they cannot share a single buffer without corrupting
    /// frame boundaries.
    private var tcpReceiveBuffers: [String: Data] = [:]

    /// Currently-applied AutoInterface group id. nil when no Auto
    /// interface is configured. Mutated only on `configQueue`.
    private var currentAutoGroupId: String?

    /// Serial queue serializing all config-state mutations and the
    /// associated NWConnection lifecycle calls so a Darwin
    /// notification fired by the app (`configChanged`) can't race
    /// `startTunnel` / `stopTunnel` / NWConnection state handlers.
    private let configQueue = DispatchQueue(label: "network.columba.tunnel.config")

    /// One-shot diagnostic UDP listener on port 9999. Used by
    /// `tools/auto-test/run_test.sh` to determine whether an
    /// iOS Network Extension can receive inbound UDP unicast at
    /// all — independent of any AutoInterface protocol logic.
    /// We hold the reference here so it stays alive across
    /// `startTunnel` / `applyConfigs` calls.
    private var diagListener: NWListener?

    /// HDLC constants
    private static let FLAG: UInt8 = 0x7E
    private static let ESC: UInt8 = 0x7D
    private static let ESC_MASK: UInt8 = 0x20

    /// AppMessage tag commands sent from the app to the extension
    /// for debugging-only purposes.
    private static let DEBUG_RELOAD_COMMAND: UInt8 = 0xFE

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[EXT] startTunnel called")
        // Write a heartbeat file we can pull from the App Group
        // container even if `ExtensionDiagLog`'s file path resolution
        // is silently failing — confirms the extension actually ran
        // and that file writes from the extension reach the shared
        // container.
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            let heartbeat = containerURL.appendingPathComponent("ext_heartbeat.txt")
            let line = "startTunnel @ \(ISO8601DateFormatter().string(from: Date()))\n"
            try? line.data(using: .utf8)?.write(to: heartbeat)
            NSLog("[EXT] heartbeat path: %@", heartbeat.path)
        } else {
            NSLog("[EXT] containerURL returned nil at startTunnel — App Group not accessible from extension")
        }
        ExtensionDiagLog.log("[EXT] startTunnel called")

        // Diagnostic listener — answers the question "can a
        // NEPacketTunnelProvider extension receive inbound UDP
        // unicast at all" independent of AutoInterface protocol
        // wiring. Test harness sends a UDP datagram to port 9999
        // from a Mac on the same Wi-Fi and checks whether
        // `[EXT/Diag] received` lands in the diag log.
        startDiagListener()

        // Diagnostic outbound test — answers "can the extension
        // send UDP unicast to the LAN at all". Sends to a hard-
        // coded test peer (the Mac's link-local address used by
        // `tools/auto-test/`); the test harness listens on
        // port 9998 and reports whether the packet arrived.
        sendDiagOutboundProbe()

        // Apply current interface configs.
        applyConfigs()

        // Subscribe to live config changes so the user adding /
        // removing / editing an interface in the app updates the
        // extension's sockets without a tunnel restart. The handler
        // diffs and only restarts what actually changed.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let provider = Unmanaged<PacketTunnelProvider>.fromOpaque(observer).takeUnretainedValue()
                provider.applyConfigs()
            },
            Self.configChangedNotification as CFString,
            nil,
            .deliverImmediately
        )

        // Set up dummy tunnel settings (required by NEPacketTunnelProvider)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["169.254.1.1"], subnetMasks: ["255.255.255.255"])
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { error in
            if let error {
                NSLog("[EXT] Failed to set tunnel settings: \(error)")
            }
            completionHandler(error)
        }
    }

    /// Read the current interface configs from shared UserDefaults
    /// and bring up / tear down the matching `NWConnection`s.
    ///
    /// Diffs against what's already running so a single relay change
    /// doesn't disrupt unrelated interfaces. Called both on
    /// `startTunnel` and on the `configChanged` Darwin notification.
    /// Always serialized onto `configQueue` so a Darwin callback
    /// arriving on a Mach-port thread can't race `startTunnel` /
    /// `stopTunnel` / NWConnection state handlers mutating the same
    /// properties.
    private func applyConfigs() {
        configQueue.async { [weak self] in
            self?.applyConfigsLocked()
        }
    }

    /// Tear down a single TCP connection by entity id and clear its
    /// HDLC receive buffer so a reconnect doesn't prepend a partial
    /// frame from the previous session to the new connection's first
    /// bytes. Always called from `configQueue`.
    private func teardownTCPConnectionLocked(entityId: String) {
        tcpConnections[entityId]?.cancel()
        tcpConnections.removeValue(forKey: entityId)
        tcpReceiveBuffers.removeValue(forKey: entityId)
    }

    /// Tear down every TCP connection (used on `stopTunnel`).
    /// Always called from `configQueue`.
    private func teardownAllTCPConnectionsLocked() {
        for (_, conn) in tcpConnections {
            conn.cancel()
        }
        tcpConnections.removeAll()
        tcpReceiveBuffers.removeAll()
    }

    /// Body of `applyConfigs` — runs on `configQueue`. Mutates
    /// `currentTCPs` / `currentAutoGroupId` / `tcpConnections` only
    /// from this serial context.
    private func applyConfigsLocked() {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        let configs = loadInterfaceConfigs(from: defaults)

        // TCP: per-entity diff. Bring up newly-configured entries,
        // tear down removed ones, restart only entries whose endpoint
        // changed. Untouched entries keep their existing connection.
        for (entityId, endpoint) in configs.tcps {
            if let existing = currentTCPs[entityId],
               existing.host == endpoint.host && existing.port == endpoint.port {
                // No change for this entity.
                continue
            }
            NSLog("[EXT] TCP config (re)applying [\(entityId)]: \(endpoint.host):\(endpoint.port)")
            teardownTCPConnectionLocked(entityId: entityId)
            startTCPConnection(entityId: entityId, host: endpoint.host, port: endpoint.port)
            currentTCPs[entityId] = endpoint
        }

        // Tear down entities the app removed.
        let desiredIds = Set(configs.tcps.keys)
        for staleId in currentTCPs.keys where !desiredIds.contains(staleId) {
            NSLog("[EXT] TCP config removed [\(staleId)]; tearing down connection")
            teardownTCPConnectionLocked(entityId: staleId)
            currentTCPs.removeValue(forKey: staleId)
        }

        // Auto: not tunneled. NEPacketTunnelProvider extensions
        // can receive UDP unicast and subscribe to multicast (we
        // verified with Mac-side test traffic + tcpdump), but
        // cannot send any UDP to the LAN — `NWConnection` reports
        // success while the packet silently never reaches the wire,
        // POSIX `sendto` returns `ENETUNREACH`, and even responses
        // on `NWListener`-accepted connections fail with
        // `ECANCELED`. Without outbound UDP we can't HELLO out for
        // discovery, can't reverse-peer to known peers, and can't
        // reply to peers that send us data — so AutoInterface in
        // the extension is fundamentally non-functional. The app's
        // local AutoInterface owns Auto for foreground use.
        _ = configs.autoGroupId
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[EXT] stopTunnel reason=\(reason.rawValue)")

        // Serialize teardown through the same queue `applyConfigs` uses
        // so we can't race a config-change notification arriving on the
        // Mach-port thread mid-shutdown. `sync` (rather than `async`)
        // keeps the existing contract that the completion handler
        // fires only after teardown has finished.
        configQueue.sync {
            teardownAllTCPConnectionsLocked()
            autoBridge.stop()
            currentTCPs.removeAll()
            currentAutoGroupId = nil
        }

        // Remove the config-changed observer registered in startTunnel.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName(Self.configChangedNotification as CFString),
            nil
        )

        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Format: [1B tag][1B idLen][N idBytes][M HDLC-framed data]
        guard messageData.count >= 1 else {
            completionHandler?(nil)
            return
        }

        // Debug commands (tags reserved 0xF0-0xFF). Lets the test
        // harness force-reload the extension so it picks up the
        // freshly-installed binary without the user toggling the
        // VPN profile in iOS Settings.
        if messageData[0] == Self.DEBUG_RELOAD_COMMAND {
            ExtensionDiagLog.log("[EXT] debug reload requested via handleAppMessage")
            completionHandler?(Data([0x01]))
            // Killing the tunnel session forces iOS to re-spawn the
            // extension process on the next start, picking up the
            // new binary on disk.
            cancelTunnelWithError(NSError(
                domain: "ColumbaDebug",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Debug reload"]
            ))
            return
        }

        guard messageData.count >= 2 else {
            completionHandler?(nil)
            return
        }

        let interfaceTag = messageData[0]
        let idLen = Int(messageData[1])
        guard messageData.count >= 2 + idLen else {
            completionHandler?(nil)
            return
        }
        let entityId: String
        if idLen > 0 {
            let idStart = messageData.index(messageData.startIndex, offsetBy: 2)
            let idEnd = messageData.index(idStart, offsetBy: idLen)
            entityId = String(data: messageData[idStart..<idEnd], encoding: .utf8) ?? ""
        } else {
            entityId = ""
        }
        let frameData = messageData.suffix(from: messageData.index(messageData.startIndex, offsetBy: 2 + idLen))

        // Read the connection / listener under configQueue so we can't
        // observe a half-mutated state while applyConfigsLocked() is
        // diffing or stopTunnel() is tearing things down.
        configQueue.async { [weak self] in
            guard let self else { completionHandler?(nil); return }
            switch interfaceTag {
            case FrameInterfaceTag.tcp.rawValue:
                // Pick the connection by entity id. If the app didn't
                // tag the frame (legacy / single-TCP build), fall back
                // to the only existing connection so behaviour matches
                // the old single-TCP path.
                let connection: NWConnection?
                if !entityId.isEmpty {
                    connection = self.tcpConnections[entityId]
                } else if self.tcpConnections.count == 1 {
                    connection = self.tcpConnections.values.first
                } else {
                    connection = nil
                }

                if let connection {
                    connection.send(content: frameData, completion: .contentProcessed { error in
                        if let error {
                            NSLog("[EXT] TCP send error [\(entityId)]: \(error)")
                        }
                    })
                } else {
                    NSLog("[EXT] No TCP connection for entityId='\(entityId)' (\(self.tcpConnections.count) connection(s) running); dropping frame")
                }
            case FrameInterfaceTag.auto.rawValue:
                // Auto isn't tunneled (extension can't send UDP to
                // the LAN — see `applyConfigsLocked`). The app's
                // AutoInterface should never enter tunnel mode, so
                // we shouldn't see auto frames here.
                NSLog("[EXT] Unexpected auto frame; auto isn't tunneled")
                ExtensionDiagLog.log("[EXT] Unexpected auto frame; auto isn't tunneled")
            default:
                NSLog("[EXT] Unknown interface tag: \(interfaceTag)")
            }
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        NSLog("[EXT] sleep")
        completionHandler()
    }

    override func wake() {
        NSLog("[EXT] wake")
        // Re-apply configs through the serial queue so dropped TCP
        // connections (cancelled / failed) get restarted without
        // racing applyConfigsLocked / stopTunnel writes. The diff
        // logic in applyConfigsLocked is a no-op when nothing
        // changed, so re-applying on wake is cheap.
        configQueue.async { [weak self] in
            guard let self else { return }
            // Treat cancelled / failed / nil connections as gone so
            // applyConfigsLocked starts a fresh one rather than seeing
            // the cached endpoint as already-applied. Use the helper
            // so the receive buffer is reset alongside the connection
            // — see `teardownTCPConnectionLocked`.
            for entityId in self.tcpConnections.keys {
                switch self.tcpConnections[entityId]?.state {
                case .cancelled, .failed, .none:
                    self.teardownTCPConnectionLocked(entityId: entityId)
                    self.currentTCPs.removeValue(forKey: entityId)
                default:
                    break
                }
            }
            self.applyConfigsLocked()
        }
    }

    // MARK: - TCP Connection

    private func startTCPConnection(entityId: String, host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        params.requiredInterfaceType = .other // Allow any interface

        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        self.tcpConnections[entityId] = connection
        self.tcpReceiveBuffers[entityId] = Data()

        connection.stateUpdateHandler = { [weak self, entityId] state in
            NSLog("[EXT] TCP state [\(entityId)]: \(state)")
            switch state {
            case .ready:
                self?.receiveTCPData(entityId: entityId)
            case .failed(let error):
                NSLog("[EXT] TCP failed [\(entityId)]: \(error), reconnecting in 5s")
                // Reconnect must go through configQueue — otherwise the
                // state-handler's write to `tcpConnections` would race
                // `applyConfigsLocked` writing the same map. Routing
                // through `applyConfigs` re-reads the current config,
                // clears the stale connection, and starts a fresh one
                // all on the serial queue.
                guard let self else { return }
                self.configQueue.async {
                    self.teardownTCPConnectionLocked(entityId: entityId)
                    self.currentTCPs.removeValue(forKey: entityId)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.applyConfigs()
                }
            case .waiting(let error):
                NSLog("[EXT] TCP waiting [\(entityId)]: \(error)")
            default:
                break
            }
        }

        // Run state callbacks AND receive callbacks on configQueue so
        // the receive buffer and connection map are touched only from
        // one serial context. Without this, a `.main` receive
        // completion could race `teardownTCPConnectionLocked`
        // resetting the buffer on configQueue and the clear would
        // silently lose to a stale append, corrupting the next
        // session's HDLC framing.
        connection.start(queue: configQueue)
    }

    /// Continuation of inbound TCP receive for a specific entity.
    /// Must run on `configQueue` because it both reads
    /// `tcpConnections[entityId]` and feeds `handleTCPData` which
    /// touches `tcpReceiveBuffers` — both serialized there.
    private func receiveTCPData(entityId: String) {
        tcpConnections[entityId]?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, entityId] data, _, isComplete, error in
            // Callback runs on the connection's queue (configQueue
            // since startTCPConnection switched it). No extra dispatch
            // needed.
            if let data, !data.isEmpty {
                self?.handleTCPData(entityId: entityId, data: data)
            }

            if isComplete {
                NSLog("[EXT] TCP connection complete [\(entityId)] (EOF)")
                return
            }

            if let error {
                NSLog("[EXT] TCP receive error [\(entityId)]: \(error)")
                return
            }

            // Continue receiving
            self?.receiveTCPData(entityId: entityId)
        }
    }

    /// Buffer TCP data and extract HDLC frames. Runs on configQueue
    /// (called from `receiveTCPData`'s completion which now executes
    /// on configQueue too). Each entity has its own receive buffer
    /// so two concurrent TCP connections cannot interleave their
    /// HDLC frame boundaries.
    private func handleTCPData(entityId: String, data: Data) {
        var buffer = tcpReceiveBuffers[entityId] ?? Data()
        buffer.append(data)

        // Extract complete HDLC frames
        let frames = extractHDLCFrames(from: &buffer)
        tcpReceiveBuffers[entityId] = buffer

        for frame in frames {
            frameQueue.append(
                frame: frame,
                interfaceTag: FrameInterfaceTag.tcp.rawValue,
                entityId: entityId
            )
        }

        if !frames.isEmpty {
            postDarwinNotification()
        }
    }

    // MARK: - Diagnostic Listener helpers

    private static func hexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Diagnostic Listener

    /// Open a plain `NWListener` on UDP port 9999 with no parameter
    /// constraints whatsoever. Logs every state transition + every
    /// inbound packet. Lets us answer empirically whether an iOS
    /// `NEPacketTunnelProvider` extension can receive inbound UDP
    /// unicast at all, instead of speculating about it.
    private func startDiagListener() {
        guard let port = NWEndpoint.Port(rawValue: 9999) else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: .udp, on: port)
        } catch {
            ExtensionDiagLog.log("[EXT/Diag] NWListener init failed: \(error)")
            return
        }
        self.diagListener = listener
        listener.stateUpdateHandler = { state in
            ExtensionDiagLog.log("[EXT/Diag] listener state: \(state)")
        }
        listener.newConnectionHandler = { conn in
            ExtensionDiagLog.log("[EXT/Diag] received from \(conn.endpoint)")
            conn.start(queue: .global(qos: .utility))
            conn.receiveMessage { content, _, _, _ in
                if let content {
                    ExtensionDiagLog.log("[EXT/Diag] payload \(content.count)B: \(Self.hexString(Data(content.prefix(32))))")
                }
                conn.cancel()
            }
        }
        listener.start(queue: .global(qos: .utility))
        ExtensionDiagLog.log("[EXT/Diag] listening on udp/9999")
    }

    // MARK: - Diagnostic Outbound

    /// Send a UDP datagram to a hard-coded Mac test address to
    /// verify whether the extension's outbound socket actually
    /// reaches the LAN. The Mac's address is the one we use from
    /// `tools/auto-test/` (`fe80::c2d:e309:eb09:6343`); listen on
    /// the Mac with `nc -lu -6 9998` while running this build.
    private func sendDiagOutboundProbe() {
        guard let host = IPv6Address("fe80::c2d:e309:eb09:6343"),
              let port = NWEndpoint.Port(rawValue: 9998) else { return }
        let conn = NWConnection(host: .ipv6(host), port: port, using: .udp)
        conn.stateUpdateHandler = { state in
            ExtensionDiagLog.log("[EXT/Diag] outbound conn state: \(state)")
            if state == .ready {
                let payload = "diag-outbound-probe-\(Date().timeIntervalSince1970)".data(using: .utf8)!
                conn.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        ExtensionDiagLog.log("[EXT/Diag] outbound probe failed: \(error)")
                    } else {
                        ExtensionDiagLog.log("[EXT/Diag] outbound probe sent (\(payload.count)B)")
                    }
                    conn.cancel()
                })
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    // MARK: - HDLC Frame Extraction

    /// Extract complete HDLC frames from a TCP buffer.
    /// Mirrors the logic in ReticulumSwift/Protocol/HDLC.swift.
    private func extractHDLCFrames(from buffer: inout Data) -> [Data] {
        var frames: [Data] = []

        while true {
            guard let startIdx = buffer.firstIndex(of: Self.FLAG) else { break }

            let searchStart = buffer.index(after: startIdx)
            guard searchStart < buffer.endIndex,
                  let endIdx = buffer[searchStart...].firstIndex(of: Self.FLAG) else { break }

            let frameContent = buffer[(buffer.index(after: startIdx))..<endIdx]
            buffer.removeSubrange(buffer.startIndex...endIdx)

            if frameContent.isEmpty { continue }

            if let unescaped = hdlcUnescape(Data(frameContent)) {
                frames.append(unescaped)
            }
        }

        return frames
    }

    /// Unescape HDLC frame content.
    private func hdlcUnescape(_ data: Data) -> Data? {
        var result = Data()
        result.reserveCapacity(data.count)
        var escapeNext = false

        for byte in data {
            if escapeNext {
                result.append(byte ^ Self.ESC_MASK)
                escapeNext = false
            } else if byte == Self.ESC {
                escapeNext = true
            } else {
                result.append(byte)
            }
        }

        return escapeNext ? nil : result
    }

    // MARK: - Darwin Notifications

    private func postDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(Self.packetReadyNotification as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Config Loading

    private struct InterfaceConfigs {
        /// Keyed by `InterfaceEntity.id` so each enabled TCP relay
        /// gets its own connection. The previous single-optional
        /// shape silently dropped every TCP entry except the last.
        var tcps: [String: (host: String, port: UInt16)] = [:]
        var autoGroupId: String?
    }

    /// Load interface configs from shared UserDefaults.
    /// Parses the same JSON format as InterfaceRepository.
    private func loadInterfaceConfigs(from defaults: UserDefaults) -> InterfaceConfigs {
        var result = InterfaceConfigs()

        guard let data = defaults.data(forKey: Self.interfacesKey) else {
            NSLog("[EXT] No interface configs found")
            return result
        }

        // Parse the JSON array — we only need type + config fields
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            NSLog("[EXT] Failed to parse interface configs")
            return result
        }

        for entity in array {
            guard let enabled = entity["enabled"] as? Bool, enabled,
                  let entityId = entity["id"] as? String,
                  let configWrapper = entity["config"] as? [String: Any],
                  let type = configWrapper["type"] as? String,
                  let config = configWrapper["config"] as? [String: Any] else {
                continue
            }

            switch type {
            case "tcpClient":
                if let host = config["targetHost"] as? String,
                   let port = config["targetPort"] as? Int {
                    result.tcps[entityId] = (host: host, port: UInt16(port))
                    NSLog("[EXT] Found TCP config [\(entityId)]: \(host):\(port)")
                }
            case "autoInterface":
                let groupId = config["groupId"] as? String ?? "reticulum"
                result.autoGroupId = groupId
                NSLog("[EXT] Found Auto config: groupId=\(groupId)")
            default:
                break
            }
        }

        return result
    }
}
