//
//  TunnelManager.swift
//  ColumbaApp
//
//  Manages the Network Extension (NEPacketTunnelProvider) lifecycle.
//  Handles loading, starting, stopping, and sending messages to the extension.
//
//  Compiled only into the experimental Model B app, whose configurations also
//  carry the Network Extension capability and entitlement.
//


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

    /// True when the initial `loadAllFromPreferences()` await timed out.
    /// Distinct from "no config exists": a live tunnel may still hold the
    /// node lease, so startup must attempt bounded recovery (see the late
    /// adoption task in `load()`).
    public private(set) var loadTimedOut = false
    /// True once a config handle exists (loaded eagerly or adopted late).
    public var hasConfigHandle: Bool { manager != nil }
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

    // MARK: - Bounded NE-preferences awaits

    /// Errors surfaced by the bounded NetworkExtension-preferences awaits.
    public enum TunnelManagerError: Error, LocalizedError, Equatable {
        /// The NE preferences XPC call (loadAllFromPreferences /
        /// saveToPreferences) did not report completion within its deadline.
        /// The completion handler for these calls is delivered over the
        /// neagent XPC and is known to be lost while a VPN session is
        /// active; awaiting them unbounded hung foreground startup forever
        /// ("Connecting to network…" never finishing after switching back
        /// from background mode). The operation is left parked (never
        /// cancelled, so the framework's continuation is never dropped);
        /// callers decide whether to retry, surface, or proceed.
        case preferencesTimedOut

        public var errorDescription: String? {
            switch self {
            case .preferencesTimedOut:
                return "The VPN configuration did not respond in time."
            }
        }
    }

    /// Thread-safe one-shot completion signal.
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        func mark() { lock.withLock { completed = true } }
        var isSet: Bool { lock.withLock { completed } }
    }

    /// True if `task` finished within `seconds`. The operation's task is
    /// never cancelled and never joined: a lost framework completion leaves
    /// it parked, which is safe (the suspended job keeps the continuation
    /// alive — no CheckedContinuation deinit trap) and strictly better than
    /// blocking a caller that must start up. The watcher mirrors `task`'s
    /// completion into the flag and is itself fire-and-forget: a task group
    /// would JOIN the watcher on exit and re-introduce the very hang this
    /// helper prevents.
    static func awaitCompleted<T, Failure: Error>(_ task: Task<T, Failure>, seconds: Double) async -> Bool {
        let flag = CompletionFlag()
        Task.detached(priority: .high) {
            _ = await task.result
            flag.mark()
        }
        let stepNs: UInt64 = 50_000_000
        // Monotonic deadline, not accumulated sleep: a busy executor or app
        // suspension can delay each wake past its requested 50 ms, and
        // counting requested sleep would silently stretch the deadline.
        let limitNs = UInt64(seconds * 1_000_000_000)
        let deadlineNs = DispatchTime.now().uptimeNanoseconds &+ limitNs
        while !flag.isSet {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs >= deadlineNs { return false }
            try? await Task.sleep(nanoseconds: min(stepNs, deadlineNs - nowNs))
        }
        return true
    }

    // MARK: - Lifecycle

    /// Load the existing VPN configuration or create a new one.
    public func load() async {
        do {
            // `loadAllFromPreferences`' completion handler rides the neagent
            // XPC and is known to be lost while a VPN session is active —
            // awaiting it unbounded hung foreground startup forever
            // ("Connecting to network…" after switching back from background
            // mode). Race it bounded; on timeout the task stays parked (its
            // continuation is never dropped, so the system wrapper cannot
            // trap) and we proceed as if no config handle exists.
            let loadTask = Task { try await NETunnelProviderManager.loadAllFromPreferences() }
            var managers: [NETunnelProviderManager] = []
            if await Self.awaitCompleted(loadTask, seconds: 5) {
                managers = try await loadTask.value
            } else {
                // A timed-out load is NOT an empty result: a live tunnel may
                // exist and keep holding the node lease. Keep the handle
                // distinct (loadTimedOut) and adopt the parked task's result
                // the moment it lands, so startup's bounded recovery can
                // still reach disable() instead of permanently dropping the
                // config.
                loadTimedOut = true
                DiagLog.log("[TUNNEL] load: loadAllFromPreferences timed out after 5s; awaiting late completion")
                Task { [weak self] in
                    guard let managers = try? await loadTask.value, let first = managers.first else { return }
                    guard let self, self.manager == nil else { return }
                    self.manager = first
                    self.isEnabled = first.isEnabled
                    self.status = first.connection.status
                    DiagLog.log("[TUNNEL] load: adopted late loadAllFromPreferences result")
                }
            }
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

    /// Stop the tunnel session WITHOUT disarming on-demand.
    ///
    /// Note: `install()` arms `isOnDemandEnabled = true` + an
    /// `NEOnDemandRuleConnect()` rule so iOS relaunches the NE after jetsam /
    /// reboot. A bare `stopVPNTunnel()` therefore does NOT keep the tunnel down —
    /// iOS re-connects via the armed rule. For the user-facing "Disable Background
    /// Transport" affordance use `disable()`, which clears on-demand first. This
    /// remains for transient internal stops where the auto-reconnect IS wanted.
    public func stop() {
        manager?.connection.stopVPNTunnel()
        logger.info("Tunnel stopped (on-demand still armed)")
    }

    /// Fully disable background transport: stop the live session, clear the
    /// on-demand connect rule and the enabled flag, then persist.
    ///
    /// Without clearing on-demand, "Disable Background Transport" is a no-op —
    /// iOS auto-resumes the NE through the `NEOnDemandRuleConnect()` armed in
    /// `install()`. Clearing `isOnDemandEnabled`/`onDemandRules`/`isEnabled`
    /// and `saveToPreferences()` is what actually keeps it down. Re-enabling
    /// via `start()` re-arms everything through `install()`. (ports #57 38f8d2e)
    ///
    /// The session is stopped BEFORE the disarm is saved: saving while a
    /// session is active is exactly the neagent contention whose completion
    /// handler can be lost, and the old unbounded `saveToPreferences()` await
    /// then hung foreground startup forever. The save is raced bounded; on
    /// timeout this throws `preferencesTimedOut` with the session already
    /// stopped — startup callers treat that as best-effort-complete (a
    /// surviving armed config is safe: the NE re-checks the selected host
    /// before initializing RNS and the flock lease serializes the node).
    public func disable() async throws {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        manager.isOnDemandEnabled = false
        manager.onDemandRules = []
        manager.isEnabled = false
        let saveTask = Task { try await manager.saveToPreferences() }
        guard await Self.awaitCompleted(saveTask, seconds: 5) else {
            DiagLog.log("[TUNNEL] disable: saveToPreferences timed out after 5s (task parked; disarm may land late)")
            isEnabled = false
            throw TunnelManagerError.preferencesTimedOut
        }
        try await saveTask.value
        isEnabled = false
        logger.info("Tunnel disabled (on-demand cleared)")
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
    /// The backend factory uses this adapter when background hosting is selected.
    public func proxySend(_ data: Data) async -> Data? {
        // The NE may still be coming up when the app first sends: proxy `start`
        // (and any early announce/status) races the tunnel session reaching
        // `.connected` at launch. `sendProviderMessage` on a non-`.connected`
        // session throws → nil → the proxy reports `ipcFailed`, and a one-time
        // launch race then leaves the proxy backend permanently "not started"
        // (the announce button later throws `transportNotConnected`). So wait
        // briefly for a live, connected session first — bounded, so a genuinely
        // down tunnel still returns nil promptly.
        guard let session = await connectedSession(timeoutMs: 8000) else {
            logger.error("proxySend: no connected tunnel session")
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

    /// Await a `.connected` `NETunnelProviderSession`, polling up to `timeoutMs`.
    /// The NE/tunnel is often still `.connecting` for a moment right after the
    /// app launches; this lets the first proxy round-trip succeed instead of
    /// spuriously failing. Returns nil if no connected session appears in time.
    private func connectedSession(timeoutMs: Int) async -> NETunnelProviderSession? {
        var waited = 0
        let step = 200
        while true {
            if let s = manager?.connection as? NETunnelProviderSession, s.status == .connected {
                return s
            }
            if waited >= timeoutMs { return nil }
            try? await Task.sleep(for: .milliseconds(step))
            waited += step
        }
    }

    /// Whether the extension is currently running.
    public var isRunning: Bool {
        status == .connected
    }

    /// Poll until the tunnel is `.connected`, up to `timeoutMs`; returns whether it
    /// connected in time. Used by the Model-B first-launch background-delivery gate to
    /// confirm the NE is actually up before the app proxies to it (so the proxy's
    /// `start()` handshake connects in seconds instead of spinning on a dead session).
    ///
    /// Delegates to `connectedSession(timeoutMs:)` so the polling logic AND the status
    /// source are shared — reading the live `manager.connection.status` rather than the
    /// cached `self.status` (which lags one main-actor hop behind the
    /// `NEVPNStatusDidChange` observer).
    public func waitUntilConnected(timeoutMs: Int) async -> Bool {
        await connectedSession(timeoutMs: timeoutMs) != nil
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
