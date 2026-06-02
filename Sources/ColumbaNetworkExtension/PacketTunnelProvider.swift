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

    private var tcpConnection: NWConnection?
    private var autoListener: NWConnectionGroup?
    private lazy var frameQueue = SharedFrameQueue(appGroupIdentifier: appGroupIdentifier)

    /// Currently-applied TCP endpoint (used to diff config changes
    /// from the app). nil when no TCP interface is configured.
    /// Mutated only on `configQueue` to avoid races with Darwin
    /// notification callbacks arriving on a Mach-port thread.
    private var currentTCP: (host: String, port: UInt16)?

    /// Currently-applied AutoInterface group id. nil when no Auto
    /// interface is configured. Mutated only on `configQueue`.
    private var currentAutoGroupId: String?

    /// Serial queue serializing all config-state mutations and the
    /// associated NWConnection lifecycle calls so a Darwin
    /// notification fired by the app (`configChanged`) can't race
    /// `startTunnel` / `stopTunnel` / NWConnection state handlers.
    private let configQueue = DispatchQueue(label: "network.columba.tunnel.config")

    /// HDLC receive buffer for TCP stream framing
    private var tcpReceiveBuffer = Data()

    /// Consecutive TCP-relay reconnect attempts since the last time the
    /// connection reached `.ready`. Drives the capped exponential
    /// backoff in `scheduleTCPReconnectLocked()`: the Nth attempt waits
    /// `min(base << N, cap)` seconds. Reset to 0 on `.ready` and on a
    /// fresh TCP (re)apply. Mutated only on `configQueue`.
    private var tcpReconnectAttempt = 0

    /// True while a backoff reconnect is already queued on `configQueue`
    /// but hasn't fired yet. Guards against a storm of `.waiting` /
    /// `.failed` callbacks stacking overlapping reconnects (each of
    /// which tears down + re-applies, which would itself re-enter
    /// `.waiting`). Cleared when the queued reconnect fires, and via
    /// `resetTCPReconnectBackoffLocked()` on `.ready` / fresh apply /
    /// wake / path-change / stop. Mutated only on `configQueue`.
    private var tcpReconnectScheduled = false

    /// Base / cap for the TCP reconnect backoff (seconds). 1, 2, 4, 8,
    /// 16, 32, then pinned at 60. The cap plus the separately-owned
    /// on-demand relaunch keep us from hammering the relay.
    private static let tcpReconnectBaseDelay: TimeInterval = 1
    private static let tcpReconnectMaxDelay: TimeInterval = 60

    /// Watches for path changes (e.g. WiFi<->cellular) so we can
    /// proactively rebuild the TCP relay connection instead of waiting
    /// for the dead socket to time out. Started in `startTunnel`,
    /// cancelled in `stopTunnel`. Its handler funnels through
    /// `configQueue`. nil before start / after stop.
    private var pathMonitor: NWPathMonitor?

    /// Last primary interface type seen by `pathMonitor`, used to
    /// distinguish a real interface switch from incidental satisfied
    /// path updates. Mutated only on `configQueue`.
    private var lastPathInterfaceType: NWInterface.InterfaceType?

    /// HDLC constants
    private static let FLAG: UInt8 = 0x7E
    private static let ESC: UInt8 = 0x7D
    private static let ESC_MASK: UInt8 = 0x20

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ExtensionDiagLog.log("startTunnel called")

        // Apply current interface configs.
        applyConfigs()

        // Watch for path changes (WiFi<->cellular, etc.) so the TCP
        // relay is rebuilt proactively rather than after the dead
        // socket times out.
        startPathMonitor()

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
                ExtensionDiagLog.log("Failed to set tunnel settings: \(error)")
            } else {
                ExtensionDiagLog.log("tunnel settings applied")
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
            guard let self else { return }
            // A "fresh" apply (startTunnel / user config change via the
            // Darwin notification) is a new situation, so reset the
            // reconnect backoff to the base. The self-driven backoff
            // retry deliberately calls `applyConfigsLocked()` directly
            // (not this wrapper) so it preserves the escalating delay.
            self.resetTCPReconnectBackoffLocked()
            self.applyConfigsLocked()
        }
    }

    /// Reset the TCP reconnect backoff to the base delay and clear any
    /// pending-reconnect guard. Called on a fresh apply, on `.ready`,
    /// and on the proactive path-change / wake re-applies. Always on
    /// `configQueue`. Does not cancel an already-queued reconnect work
    /// item — clearing the flag just lets the next failure schedule a
    /// fresh (base-delay) one, and the stale item's `applyConfigsLocked`
    /// is a harmless no-op when nothing changed.
    private func resetTCPReconnectBackoffLocked() {
        tcpReconnectAttempt = 0
        tcpReconnectScheduled = false
    }

    /// Tear down the current TCP connection and clear the HDLC
    /// receive buffer so a reconnect doesn't prepend a partial frame
    /// from the previous session to the new connection's first
    /// bytes (which would corrupt the next decoded packet). Always
    /// called from `configQueue`.
    private func teardownTCPConnectionLocked() {
        tcpConnection?.cancel()
        tcpConnection = nil
        tcpReceiveBuffer = Data()
    }

    /// Schedule a TCP-relay reconnect with capped exponential backoff.
    /// The delay doubles each consecutive failure (1, 2, 4, 8, 16, 32,
    /// 60s cap) and is reset to the base when the connection next
    /// reaches `.ready` (see `startTCPConnection`) or a fresh config is
    /// applied. Always called from `configQueue`; the reconnect itself
    /// is dispatched back onto `configQueue` so the `tcpConnection`
    /// pointer and `tcpReceiveBuffer` are still only touched serially —
    /// no unsynchronized timer races `applyConfigsLocked` / `stopTunnel`.
    ///
    /// Idempotent within a backoff cycle: if a reconnect is already
    /// queued (`tcpReconnectScheduled`) this is a no-op, so a burst of
    /// `.waiting`/`.failed` callbacks can't stack overlapping reconnects.
    private func scheduleTCPReconnectLocked() {
        // Tear down the dead socket immediately (resets `tcpReceiveBuffer`
        // so a half-frame can't corrupt the next connection's framing)
        // and forget the cached endpoint so applyConfigsLocked rebuilds
        // it rather than treating it as already-applied. Do this even if
        // a reconnect is already queued — the socket is gone regardless.
        teardownTCPConnectionLocked()
        currentTCP = nil

        guard !tcpReconnectScheduled else { return }
        tcpReconnectScheduled = true

        let exponent = min(tcpReconnectAttempt, 16) // cap the exponent; pow result is clamped to the 60s cap below anyway
        let delay = min(
            Self.tcpReconnectBaseDelay * pow(2.0, Double(exponent)),
            Self.tcpReconnectMaxDelay
        )
        tcpReconnectAttempt += 1

        ExtensionDiagLog.log("TCP relay reconnect scheduled in \(Int(delay))s (attempt \(tcpReconnectAttempt))")

        configQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.tcpReconnectScheduled = false
            // Re-reads the current config and brings the connection back
            // up (no-op if the TCP interface was meanwhile removed).
            self.applyConfigsLocked()
        }
    }

    /// Body of `applyConfigs` — runs on `configQueue`. Mutates
    /// `currentTCP` / `currentAutoGroupId` / `tcpConnection` /
    /// `autoListener` only from this serial context.
    private func applyConfigsLocked() {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        let configs = loadInterfaceConfigs(from: defaults)

        // TCP: bring up if newly configured; tear down if removed;
        // restart if endpoint changed.
        if let tcp = configs.tcp {
            if let existing = currentTCP, existing.host == tcp.host && existing.port == tcp.port {
                // No change.
            } else {
                // NO-PII: never log tcp.host / tcp.port (relay endpoint).
                ExtensionDiagLog.log("TCP relay config (re)applying")
                teardownTCPConnectionLocked()
                startTCPConnection(host: tcp.host, port: tcp.port)
                currentTCP = (tcp.host, tcp.port)
            }
        } else if currentTCP != nil {
            ExtensionDiagLog.log("TCP relay config removed; tearing down connection")
            teardownTCPConnectionLocked()
            currentTCP = nil
        }

        // Auto: same diff.
        if let groupId = configs.autoGroupId {
            if currentAutoGroupId == groupId {
                // No change.
            } else {
                // groupId is a non-secret multicast group label (e.g. "reticulum"),
                // not an address — safe to log.
                ExtensionDiagLog.log("Auto config (re)applying: groupId=\(groupId)")
                autoListener?.cancel()
                autoListener = nil
                startAutoListener(groupId: groupId)
                currentAutoGroupId = groupId
            }
        } else if currentAutoGroupId != nil {
            ExtensionDiagLog.log("Auto config removed; tearing down listener")
            autoListener?.cancel()
            autoListener = nil
            currentAutoGroupId = nil
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ExtensionDiagLog.log("stopTunnel reason=\(reason.rawValue)")

        // Serialize teardown through the same queue `applyConfigs` uses
        // so we can't race a config-change notification arriving on the
        // Mach-port thread mid-shutdown. `sync` (rather than `async`)
        // keeps the existing contract that the completion handler
        // fires only after teardown has finished.
        configQueue.sync {
            stopPathMonitorLocked()
            teardownTCPConnectionLocked()
            autoListener?.cancel()
            autoListener = nil
            currentTCP = nil
            currentAutoGroupId = nil
            // Drop any pending reconnect state so a queued backoff work
            // item is a no-op (its applyConfigsLocked sees no config).
            resetTCPReconnectBackoffLocked()
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

    // MARK: - Path Monitoring

    /// Start watching for network path changes. Created lazily and run
    /// on `configQueue` so its `pathUpdateHandler` is serialized with
    /// every connection / config mutation — no separate queue to funnel
    /// back from. Idempotent: a second call cancels the prior monitor
    /// first. Called from `startTunnel`.
    private func startPathMonitor() {
        configQueue.async { [weak self] in
            guard let self else { return }
            self.stopPathMonitorLocked()

            let monitor = NWPathMonitor()
            self.pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                // Already on `configQueue` (see `monitor.start(queue:)`).
                self?.handlePathUpdateLocked(path)
            }
            monitor.start(queue: self.configQueue)
            ExtensionDiagLog.log("Path monitor started")
        }
    }

    /// Cancel + clear the path monitor. Always called on `configQueue`.
    private func stopPathMonitorLocked() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathInterfaceType = nil
    }

    /// React to a path update. Runs on `configQueue`.
    ///
    /// On a *satisfied* path whose primary interface type changed (e.g.
    /// WiFi -> cellular) while a TCP relay is configured, proactively
    /// tear down + re-apply so the relay rebinds to the new interface
    /// immediately rather than after the stale socket times out. The
    /// interface-type comparison guards against re-applying on every
    /// incidental satisfied update.
    ///
    /// NO-PII: logs only the coarse interface-type label
    /// ("wifi"/"cellular"/"wiredEthernet"/"loopback"/"other"), never an
    /// SSID, interface name, or address.
    private func handlePathUpdateLocked(_ path: Network.NWPath) {
        guard path.status == .satisfied else {
            // Unsatisfied / requires-connection: nothing to rebind onto
            // yet. Leave the interface label so the next satisfied path
            // is compared against the last *working* interface.
            return
        }

        let newType = Self.primaryInterfaceType(of: path)
        let previousType = lastPathInterfaceType
        lastPathInterfaceType = newType

        // First satisfied path after start: record the baseline, don't
        // churn the (just-applied) connection.
        guard let previousType else { return }

        guard newType != previousType else { return } // no real interface switch

        ExtensionDiagLog.log(
            "Path changed: \(Self.label(for: previousType)) -> \(Self.label(for: newType))"
        )

        // Only churn the relay if one is actually configured/active.
        guard currentTCP != nil else { return }

        ExtensionDiagLog.log("Rebuilding TCP relay for interface change")
        // A fresh interface is a new situation — reset backoff so the
        // rebind starts at the base delay.
        resetTCPReconnectBackoffLocked()
        teardownTCPConnectionLocked()
        currentTCP = nil // force applyConfigsLocked to rebuild rather than diff-skip
        applyConfigsLocked()
    }

    /// The path's primary (first available) interface type, or nil if
    /// the path reports none.
    private static func primaryInterfaceType(of path: Network.NWPath) -> NWInterface.InterfaceType? {
        for type: NWInterface.InterfaceType in [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        where path.usesInterfaceType(type) {
            return type
        }
        return path.availableInterfaces.first?.type
    }

    /// Coarse, PII-free label for an interface type.
    private static func label(for type: NWInterface.InterfaceType?) -> String {
        guard let type else { return "none" }
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wiredEthernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Format: [1-byte interface tag][N-byte HDLC-framed data]
        guard messageData.count >= 2 else {
            completionHandler?(nil)
            return
        }

        let interfaceTag = messageData[0]
        let frameData = messageData.dropFirst()

        // Read the connection / listener under configQueue so we can't
        // observe a half-mutated state while applyConfigsLocked() is
        // diffing or stopTunnel() is tearing things down.
        configQueue.async { [weak self] in
            guard let self else { completionHandler?(nil); return }
            switch interfaceTag {
            case FrameInterfaceTag.tcp.rawValue:
                self.tcpConnection?.send(content: frameData, completion: .contentProcessed { error in
                    if let error {
                        ExtensionDiagLog.log("TCP send error: \(error)")
                    }
                })
            case FrameInterfaceTag.auto.rawValue:
                // Auto frames are sent as UDP datagrams via the connection group
                self.autoListener?.send(content: frameData) { error in
                    if let error {
                        ExtensionDiagLog.log("Auto send error: \(error)")
                    }
                }
            default:
                ExtensionDiagLog.log("Unknown interface tag: \(interfaceTag)")
            }
            completionHandler?(nil)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        ExtensionDiagLog.log("sleep")
        completionHandler()
    }

    override func wake() {
        ExtensionDiagLog.log("wake")
        // Re-apply configs through the serial queue so a dropped TCP
        // connection (cancelled / failed) gets restarted without
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
            switch self.tcpConnection?.state {
            case .cancelled, .failed, .none:
                self.teardownTCPConnectionLocked()
                self.currentTCP = nil
            default:
                break
            }
            // Wake is a fresh situation — reset the reconnect backoff so a
            // post-sleep reconnect doesn't inherit a long stale delay.
            self.resetTCPReconnectBackoffLocked()
            self.applyConfigsLocked()
        }
    }

    // MARK: - TCP Connection

    private func startTCPConnection(host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        params.requiredInterfaceType = .other // Allow any interface

        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        self.tcpConnection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            // Runs on `configQueue` (see `connection.start(queue:)`
            // below), so it's serialized with every `tcpConnection` /
            // backoff mutation and can call the `*Locked` helpers
            // directly — no extra dispatch.
            //
            // NO-PII: do NOT interpolate the raw NWConnection.State — its
            // description can embed the endpoint host:port. Log only the
            // case label (and sanitized NWError descriptions below).
            guard let self else { return }

            // Ignore callbacks from a stale connection: teardown /
            // reconnect may have already replaced `tcpConnection`, and a
            // late `.failed`/`.waiting` from the previous socket must not
            // tear down the live one.
            guard let connection, connection === self.tcpConnection else { return }

            switch state {
            case .ready:
                ExtensionDiagLog.log("TCP relay state: ready")
                // Connection succeeded — reset the reconnect backoff so the
                // next drop starts at the base delay again.
                self.resetTCPReconnectBackoffLocked()
                self.receiveTCPData()
            case .failed(let error):
                ExtensionDiagLog.log("TCP relay failed: \(error)")
                // Capped exponential backoff (1,2,4,…,60s). Tears down the
                // dead socket + resets `tcpReceiveBuffer`, then schedules
                // the re-apply on `configQueue`.
                self.scheduleTCPReconnectLocked()
            case .waiting(let error):
                // `.waiting` means the path is currently unsatisfiable
                // (e.g. no route). Treat it like a failure for backoff
                // purposes; the guard in `scheduleTCPReconnectLocked`
                // collapses a storm of `.waiting` callbacks into a single
                // pending reconnect.
                ExtensionDiagLog.log("TCP relay waiting: \(error)")
                self.scheduleTCPReconnectLocked()
            default:
                break
            }
        }

        // Run state callbacks AND receive callbacks on configQueue so
        // the receive buffer (`tcpReceiveBuffer`) and connection
        // pointer are touched only from one serial context. Without
        // this, a `.main` receive completion could race
        // `teardownTCPConnectionLocked` resetting the buffer on
        // configQueue and the clear would silently lose to a stale
        // append, corrupting the next session's HDLC framing.
        connection.start(queue: configQueue)
    }

    /// Continuation of inbound TCP receive. Must run on `configQueue`
    /// because it both reads `tcpConnection` and feeds `handleTCPData`
    /// which touches `tcpReceiveBuffer` — both serialized there.
    private func receiveTCPData() {
        tcpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            // Callback runs on the connection's queue (configQueue
            // since startTCPConnection switched it). No extra dispatch
            // needed.
            if let data, !data.isEmpty {
                self?.handleTCPData(data)
            }

            if isComplete {
                ExtensionDiagLog.log("TCP relay connection complete (EOF)")
                return
            }

            if let error {
                ExtensionDiagLog.log("TCP relay receive error: \(error)")
                return
            }

            // Continue receiving
            self?.receiveTCPData()
        }
    }

    /// Buffer TCP data and extract HDLC frames. Runs on configQueue
    /// (called from `receiveTCPData`'s completion which now executes
    /// on configQueue too).
    private func handleTCPData(_ data: Data) {
        tcpReceiveBuffer.append(data)

        // Extract complete HDLC frames
        let frames = extractHDLCFrames(from: &tcpReceiveBuffer)

        for frame in frames {
            frameQueue.append(frame: frame, interfaceTag: FrameInterfaceTag.tcp.rawValue)
        }

        if !frames.isEmpty {
            postDarwinNotification()
        }
    }

    // MARK: - AutoInterface Multicast Listener

    private func startAutoListener(groupId: String) {
        // AutoInterface uses link-local multicast on a well-known group/port
        // The discovery and data ports match ReticulumSwift AutoInterface defaults
        let discoveryPort: UInt16 = 29716
        let multicastGroup: NWMulticastGroup
        do {
            multicastGroup = try NWMulticastGroup(for: [
                .hostPort(host: .ipv6(IPv6Address("ff02::1")!), port: NWEndpoint.Port(rawValue: discoveryPort)!)
            ])
        } catch {
            ExtensionDiagLog.log("Failed to create multicast group: \(error)")
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .other

        let group = NWConnectionGroup(with: multicastGroup, using: params)
        self.autoListener = group

        group.stateUpdateHandler = { state in
            // Auto multicast uses the fixed link-local group ff02::1 (a constant,
            // not the user's LAN address), but log only the case label to keep
            // the channel uniformly endpoint-free.
            switch state {
            case .ready: ExtensionDiagLog.log("Auto multicast state: ready")
            case .failed: ExtensionDiagLog.log("Auto multicast state: failed")
            case .waiting: ExtensionDiagLog.log("Auto multicast state: waiting")
            case .cancelled: ExtensionDiagLog.log("Auto multicast state: cancelled")
            default: break
            }
        }

        group.setReceiveHandler(maximumMessageSize: 2048, rejectOversizedMessages: false) { [weak self] message, content, isComplete in
            guard let content, !content.isEmpty else { return }

            // Auto frames are complete UDP datagrams (no HDLC framing needed)
            self?.frameQueue.append(frame: content, interfaceTag: FrameInterfaceTag.auto.rawValue)
            self?.postDarwinNotification()
        }

        group.start(queue: .main)
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
        var tcp: (host: String, port: UInt16)?
        var autoGroupId: String?
    }

    /// Load interface configs from shared UserDefaults.
    /// Parses the same JSON format as InterfaceRepository.
    private func loadInterfaceConfigs(from defaults: UserDefaults) -> InterfaceConfigs {
        var result = InterfaceConfigs()

        guard let data = defaults.data(forKey: Self.interfacesKey) else {
            ExtensionDiagLog.log("No interface configs found")
            return result
        }

        // Parse the JSON array — we only need type + config fields
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            ExtensionDiagLog.log("Failed to parse interface configs")
            return result
        }

        for entity in array {
            guard let enabled = entity["enabled"] as? Bool, enabled,
                  let configWrapper = entity["config"] as? [String: Any],
                  let type = configWrapper["type"] as? String,
                  let config = configWrapper["config"] as? [String: Any] else {
                continue
            }

            switch type {
            case "tcpClient":
                if let host = config["targetHost"] as? String,
                   let port = config["targetPort"] as? Int {
                    result.tcp = (host: host, port: UInt16(port))
                    // NO-PII: never log host / port (the relay endpoint).
                    ExtensionDiagLog.log("Found TCP relay config")
                }
            case "autoInterface":
                let groupId = config["groupId"] as? String ?? "reticulum"
                result.autoGroupId = groupId
                ExtensionDiagLog.log("Found Auto config: groupId=\(groupId)")
            default:
                break
            }
        }

        return result
    }
}
