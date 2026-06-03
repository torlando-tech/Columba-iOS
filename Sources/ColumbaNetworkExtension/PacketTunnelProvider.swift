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

    /// Model B in-NE Reticulum + LXMF node (Track A5a + C3). Constructed + started
    /// in `startTunnel` ONLY when `NEReticulumNode.modelBNodeEnabled` (the shared
    /// App-Group flag `modelBBackgroundNE`, default `false`) is `true`. When it's
    /// non-nil the node is the LIVE delivery path — it owns its TCP relay
    /// interface + the AppGroupBridge — and the PoC dumb-pipe (the NWConnection
    /// forwarding above) is bypassed (`applyConfigs()` / `wake()` re-apply are
    /// skipped) so the relay isn't double-bound. `nil` (the default) ⇒ the PoC
    /// dumb-pipe is the sole delivery path, exactly as before.
    private var reticulumNode: NEReticulumNode?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ExtensionDiagLog.log("startTunnel called")

        // ── Model B vs PoC delivery path (unified runtime switch, Track C3) ──────
        // `NEReticulumNode.modelBNodeEnabled` is the SHARED App-Group flag
        // (`modelBBackgroundNE`, the SAME key `BackendPreference.modelB` reads),
        // **default FALSE**. The two paths are mutually exclusive so the relay is
        // never double-bound:
        //
        //   • FALSE (default / shipping fallback): the PoC dumb-pipe. `applyConfigs()`
        //     brings up the raw NWConnection relay forwarding, the path monitor +
        //     `configChanged` observer keep it healthy, and the in-NE node stays nil.
        //
        //   • TRUE (opt-in device-test): the in-NE Reticulum + LXMF node is the LIVE
        //     delivery path. It OWNS its own TCP relay interface (read from the same
        //     App-Group config) + the AppGroupBridge, so we MUST skip the PoC
        //     `applyConfigs()` here — otherwise the node's relay socket and the PoC
        //     NWConnection would both bind the relay (double connection / duplicate
        //     delivery). `start()` is a clean no-op if the shared identity isn't
        //     available yet.
        let modelBActive = NEReticulumNode.modelBNodeEnabled
        if modelBActive {
            ExtensionDiagLog.log("startTunnel: Model B active — in-NE node owns delivery; skipping PoC dumb-pipe")
            let node = NEReticulumNode()
            self.reticulumNode = node
            Task {
                do {
                    _ = try await node.start()
                } catch {
                    ExtensionDiagLog.log("startTunnel: NEReticulumNode.start failed: \(String(describing: error))")
                }
            }
        } else {
            // PoC path: apply current interface configs (raw relay forwarding).
            applyConfigs()
        }

        // Watch for path changes (WiFi<->cellular, etc.) so the TCP
        // relay is rebuilt proactively rather than after the dead
        // socket times out. Only meaningful for the PoC path — the
        // Model B node's `TCPInterface` self-reconnects (see the
        // C3-followup reconnect-parity TODO in `NEReticulumNode.start`).
        if !modelBActive {
            startPathMonitor()
        }

        // Subscribe to live config changes so the user adding /
        // removing / editing an interface in the app updates the
        // extension's sockets without a tunnel restart. The handler
        // diffs and only restarts what actually changed. Skipped under
        // Model B: the node owns its interfaces and `applyConfigs()`
        // (which this fires) is the PoC path we deliberately bypass.
        if !modelBActive {
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
        }

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

        // Remove the config-changed observer registered in startTunnel (PoC path
        // only). Harmless no-op under Model B, where it was never added — the PoC
        // teardown above is likewise a no-op when the dumb-pipe was never started.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName(Self.configChangedNotification as CFString),
            nil
        )

        // Track C3: tear down the in-NE node if it was started (Model B path; nil
        // when the flag was off and the PoC dumb-pipe ran instead). Stopping the
        // node drops its TCP relay interface + AppGroupBridge. Fire-and-forget —
        // teardown is best-effort and the completion handler must not block on it.
        if let node = reticulumNode {
            reticulumNode = nil
            Task { await node.stop() }
        }

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
        // ── Track A5b (Model B app→NE send path) ────────────────────────────────
        // A `ProxyRequest` envelope is marked by a leading magic byte
        // (`ProxyIPC.magic` = 0xF5) that the PoC interface-tag space (tcp = 0x01,
        // auto = 0x02) never uses, so we can branch on it unambiguously. If the
        // incoming data is a ProxyRequest, dispatch it to the in-NE node and reply
        // with an encoded `ProxyResponse`; otherwise fall through to the existing
        // PoC frame-forwarding below (untouched). Inert by default:
        // `reticulumNode` is nil unless `NEReticulumNode.modelBNodeEnabled` is true
        // (the App-Group flag, default off), so a ProxyRequest answers
        // `.unsupported` until the user opts into Model B.
        if ProxyIPC.isProxyRequest(messageData) {
            handleProxyRequest(messageData, completionHandler: completionHandler)
            return
        }

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
                ExtensionDiagLog.log("[BRIDGE] app->NE frame tag=\(interfaceTag) len=\(frameData.count) -> relay")
                self.tcpConnection?.send(content: frameData, completion: .contentProcessed { error in
                    if let error {
                        ExtensionDiagLog.log("TCP send error: \(error)")
                    }
                })
            case FrameInterfaceTag.auto.rawValue:
                ExtensionDiagLog.log("[BRIDGE] app->NE frame tag=\(interfaceTag) len=\(frameData.count) -> relay")
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

    // MARK: - Track A5b — Model B app→NE IPC dispatch

    /// Decode a `ProxyRequest` envelope and dispatch it to the in-NE
    /// `NEReticulumNode`, replying through `completionHandler` with an encoded
    /// `ProxyResponse`. Only called from `handleAppMessage` once the magic prefix
    /// has matched. If the node isn't running (the default case — `modelBNodeEnabled`
    /// is off, so the node was never constructed), every op replies `.unsupported`
    /// so the app degrades gracefully.
    ///
    /// `ProxyRequest` / `ProxyResponse` / `ProxyLocalInfo` / `ProxySendOutcome`
    /// live in the Foundation-only `ProxyIPC` (Shared target, linked into the NE),
    /// so this honors the NE's RNSAPI-free collision rule.
    private func handleProxyRequest(_ data: Data, completionHandler: ((Data?) -> Void)?) {
        // A malformed envelope (magic matched but JSON body undecodable) is a
        // protocol error, not a PoC frame — reply `.error` rather than falling
        // through (the magic byte already proved intent).
        let request: ProxyRequest?
        do {
            request = try ProxyIPC.decodeRequest(data)
        } catch {
            completionHandler?(ProxyIPC.encodeResponse(.error("malformed ProxyRequest")))
            return
        }
        guard let request else {
            completionHandler?(ProxyIPC.encodeResponse(.error("unrecognized ProxyRequest envelope")))
            return
        }

        // Snapshot the node reference. Nil ⇒ the Model B node isn't running
        // (flag off — the default — or not yet started): reply `.unsupported`.
        guard let node = reticulumNode else {
            completionHandler?(ProxyIPC.encodeResponse(.unsupported))
            return
        }

        Task {
            let response = await Self.dispatch(request, to: node)
            completionHandler?(ProxyIPC.encodeResponse(response))
        }
    }

    /// Route a decoded `ProxyRequest` to the node and build its `ProxyResponse`.
    /// `nonisolated`/`static` so it can be awaited from the detached `Task` above
    /// without capturing `self`.
    private static func dispatch(_ request: ProxyRequest, to node: NEReticulumNode) async -> ProxyResponse {
        switch request {
        case .start:
            // The node loads its own shared identity + store path; the display
            // name isn't needed to *start* (announce carries it). A start that
            // can't bring up the node (no identity yet) ⇒ `.unsupported`.
            do {
                let started = try await node.start()
                guard started, let info = await node.localInfoForIPC() else {
                    return .unsupported
                }
                let payload = try? JSONEncoder().encode(info)
                return .ok(payload)
            } catch {
                return .error(String(describing: error))
            }

        case .stop:
            await node.stop()
            return .ok(nil)

        case .announce(let displayName):
            let ok = await node.announceForIPC(displayName: displayName)
            return .ok(try? JSONEncoder().encode(ok))

        case .announceTelephony(let displayName):
            let ok = await node.announceTelephonyForIPC(displayName: displayName)
            return .ok(try? JSONEncoder().encode(ok))

        case .statusSnapshot:
            guard let json = await node.statusSnapshotJSONForIPC() else {
                return .ok(nil)
            }
            return .ok(json)

        case .heardAnnounces:
            guard let json = await node.heardAnnouncesJSONForIPC() else {
                return .ok(nil)
            }
            return .ok(json)

        case .persist:
            let ok = await node.persistForIPC()
            return ok ? .ok(nil) : .error("persist failed")

        case .registeredDestinationHashes:
            let hashes = await node.registeredDestinationHashesForIPC()
            return .ok(try? JSONEncoder().encode(hashes))

        case .lxmfSend(let destHashHex, let content, let method, let fieldsData):
            let outcome = await node.sendLxmfForIPC(
                destHashHex: destHashHex, content: content, method: method, fieldsData: fieldsData)
            return .ok(try? JSONEncoder().encode(outcome))
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        ExtensionDiagLog.log("sleep")
        completionHandler()
    }

    override func wake() {
        ExtensionDiagLog.log("wake")
        // Under Model B the in-NE node owns the relay (its `TCPInterface`
        // self-reconnects), and the PoC dumb-pipe never ran — so re-applying the
        // PoC configs here would START a duplicate NWConnection to the relay
        // (double-bind). Skip the PoC wake path entirely when the node is active.
        guard reticulumNode == nil else { return }

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
            // Bridge diagnostic: relay bytes in -> HDLC frames queued for the app.
            // NO-PII: byte length + frame count only. Low-noise (frames>0 only).
            ExtensionDiagLog.log("[BRIDGE] relay->NE \(data.count)B -> \(frames.count) frame(s) queued")
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
