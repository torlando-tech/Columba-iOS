//
//  PacketTunnelProvider.swift
//  ColumbaNetworkExtension
//
//  NEPacketTunnelProvider host for the Model B in-NE Reticulum + LXMF node.
//  Model B is the SOLE architecture on the build that compiles the NE in
//  (ENABLE_NETWORK_EXTENSION ⇔ COLUMBA_BACKEND_SWIFT): the extension exists
//  solely to own and keep alive the in-NE Python RNS node (`PythonNodeEngine` over
//  the embedded CPython) — the background LXMF delivery path — while the main
//  app is backgrounded. It carries NO raw-frame forwarding: the node owns its
//  own TCP relay interface + the AppGroupBridge, and the app→NE send path is
//  the `ProxyRequest`/`ProxyResponse` IPC handled in `handleAppMessage` below.
//  (The abandoned C++ microReticulum node is gone; Python RNS is the sole
//  runtime in the NE.)
//
//  (The earlier "Model A" PoC dumb-pipe — NWConnection TCP/Auto frame forwarding
//  over a shared HDLC queue, with an NWPathMonitor + a Darwin config-change
//  observer + exponential reconnect backoff — was removed once Model B became the
//  only architecture. See git history if that raw-relay code is ever needed.)
//

import Foundation
import Network
import NetworkExtension
import UserNotifications
import ColumbaNode
import SwiftBLEBridge

class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Node-service v1 node owner (contract 6)

    /// The node-owner coordinator for the bounded control channel. Wraps the
    /// in-NE Python RNS engine behind the `NodeEngine` seam + the shared durable
    /// `NodeStore`. The app reaches it exclusively over `[0xF5 0x02]` control
    /// frames in `handleAppMessage`. The LEGACY `ProxyRequest` path is preserved
    /// (contract 16: cut over later) — it still handles the non-control `0xF5`
    /// envelopes.
    ///
    /// SINGLE RUNTIME: the NE hosts exactly ONE Reticulum runtime — Python RNS
    /// (the abandoned ReticulumSwift/LXMFSwift C++ microReticulum node was
    /// removed; it cannot coexist with Python RNS in the NE's memory budget, and
    /// is not part of the target architecture). Until the Python RNS engine
    /// conformance lands, the owner runs the engine-agnostic fail-closed
    /// `StubEngine`; the control channel stays reachable + honest. Wiring the
    /// real engine requires `PythonNodeEngine` (or a dedicated adapter) to conform
    /// to `NodeEngine`, and integration work on admission recovery, execution
    /// recovery, and the app facade before the control channel can route real
    /// sends. Until that is complete the `test-node-send` deep link is the
    /// device plumbing test for the channel framing/store/admission path only.
    private var nodeOwner: NodeOwner?

    private let hostObservers = NodeHostObservers()

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ExtensionDiagLog.log("startTunnel called")
        guard NodeHostingMode.current == .networkExtension else {
            completionHandler(NSError(domain: "Columba.NodeHost", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Foreground-only mode is selected"]))
            return
        }
        // Self-reported memory trajectory. The app cannot measure this process
        // from outside its own sandbox, and a jetsam kill delivers no callback,
        // so the NE is the only thing that can record what it was using. The
        // sampler runs on its own native thread: the main dispatch thread is
        // blocked during bring-up and announce floods.
        NEMemoryTrace.start()

        // Storage census: occupancy, net change, and modification metadata,
        // not per-file write attribution or bytes charged by iOS. The read-only,
        // low-memory scan is bounded and cancellable; logs contain no PII.
        // Incomplete scans are marked and excluded from comparisons.
        NEDiskCensus.start()

        // SINGLE RUNTIME: Python RNS is the only Reticulum runtime in the NE.
        // Initialize CPython here (non-blocking - it must never gate tunnel
        // bring-up). The actual node is brought up lazily when the app's first
        // `.start` IPC arrives (dispatchPython → PythonNodeEngine.start), which loads
        // the shared identity + the app-written shared config. Until then the
        // engine is ready-but-not-running, and `.start` replies `.unsupported`
        // (or brings the node up) accordingly.
        Task {
            switch PythonNodeRuntime.shared.start() {
            case .success:
                ExtensionDiagLog.log("[NE-PY-RNS] python ready (node starts on first .start IPC)")
                // Auto-restart: if the app previously started a node (persisted
                // display name + shared config dir exist), bring it up now.
                // This covers the tunnel-session-reconnect relaunch case where
                // the in-process RNS restart already ran but the NE was killed
                // before the app re-sent .start. Idempotent: if the app sends
                // .start later, engine.start() is a no-op restart.
                let defaults = UserDefaults(suiteName: "group.network.columba.Columba")
                if let name = defaults?.string(forKey: "rnsLastDisplayName") {
                    let configDir = (PythonNodeEngine.sharedConfigDir() as NSString).appendingPathComponent("config")
                    if FileManager.default.fileExists(atPath: configDir) {
                        ExtensionDiagLog.log("[NE-PY-RNS] auto-start: config found, starting node")
                        if PythonNodeEngine.shared.start(displayName: name) != nil {
                            ExtensionDiagLog.log("[NE-PY-RNS] auto-start: node started")
                        } else {
                            ExtensionDiagLog.log("[NE-PY-RNS] auto-start: start failed (no identity?)")
                        }
                    }
                }
            case .failure(let err):
                ExtensionDiagLog.log("[NE-PY-RNS] init failed: \(err.localizedDescription)")
            }
        }

        // Model B BLE: the mesh CoreBluetooth radio (SwiftBLEBridge) now runs
        // IN-PROCESS in the NE (Phase 2). Wire its event callback into the
        // driver's Python callback slots and force-link the package's
        // `columba_ble_*` C-ABI into this dylib. Idempotent; install before the
        // Python driver issues its first `columba_ble_start` so early events
        // land in the driver. The hook wires lazily (checks Python state at
        // event time), so ordering vs Python init does not matter.
        PythonNodeBridgeHook.wireToPython()
        PythonNodeBLECallbackInvoker.install()

        // Set up dummy tunnel settings (required by NEPacketTunnelProvider)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["169.254.1.1"], subnetMasks: ["255.255.255.255"])
        settings.mtu = 1500

        // Model B: listen for the NE's inbound-banner ping so the user gets a
        // banner even while the app is suspended / terminated (the tunnel keeps
        // this process alive). Independent of tunnel-settings bring-up.
        hostObservers.start()
        // Live-refresh of the block_unknown_senders privacy filter (Issue 3).


        setTunnelNetworkSettings(settings) { error in
            if let error {
                ExtensionDiagLog.log("Failed to set tunnel settings: \(error)")
            } else {
                ExtensionDiagLog.log("tunnel settings applied")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ExtensionDiagLog.log("stopTunnel reason=\(reason.rawValue)")
        // Writing this marker is what lets the app tell a clean teardown from a
        // kill. A memory kill never reaches here, so its absence is the signal.
        NEMemoryTrace.recordStop(reason: reason.rawValue)
        NEDiskCensus.stop()

        // Track C3: tear down the in-NE node. Stopping the node drops its TCP
        // relay interface + AppGroupBridge. Fire-and-forget — teardown is
        // best-effort and the completion handler must not block on it.
        // Also release the node owner (releases its shared NodeStore connection;
        // the store is durable WAL, so a clean close here is safe).
        // SINGLE RUNTIME: tear down the in-NE Python RNS engine. Stopping it
        // drops the node's transport + router. Fire-and-forget - teardown is
        // best-effort and the completion handler must not block on it.
        Task {
            PythonNodeEngine.shared.stop()
            nodeOwner = nil
        }

        // Drop the inbound-banner observer (no more banners once the node is down).
        hostObservers.stop()
        // Drop the block_unknown_senders live-refresh observer.


        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // ── Node-service v1 control channel (contract 6) ───────────────────────
        // A `[0xF5, 0x02]` frame is a CONTROL message, full stop. Check it BEFORE
        // the legacy `ProxyRequest` branch (which matches any `0xF5` first byte):
        // an unknown control version is a hard control-protocol error that replies
        // a typed failure — it must NEVER fall through to the legacy path
        // (contract 6). The control path is engine-agnostic + async, so it
        // dispatches on a Task and hands the framed reply back through the
        // completion handler (the 1:1 request/response channel).
        if ControlChannel.isControlFrame(messageData) {
            let owner = nodeOwnerIfNeeded()
            guard let owner else {
                // Node owner unavailable (no shared store / node not up): a
                // typed failure rather than a silent fallthrough to legacy.
                completionHandler?(ProxyIPC.encodeResponse(.error("node owner not ready")))
                return
            }
            Task {
                let reply = await owner.handle(messageData)
                completionHandler?(reply)
            }
            return
        }

        // ── Track A5b (Model B app→NE send path, LEGACY) ───────────────────────
        // The app talks to the NE node via `ProxyRequest` envelopes, marked by a
        // leading magic byte (`ProxyIPC.magic` = 0xF5, version 0x01). Decode +
        // reply with an encoded `ProxyResponse`. Any non-ProxyRequest message is
        // ignored. Preserved alongside the control channel (contract 16).
        if ProxyIPC.isProxyRequest(messageData) {
            handleProxyRequest(messageData, completionHandler: completionHandler)
            return
        }
        completionHandler?(nil)
    }

    /// Build (once per boot) the node-owner coordinator over the shared durable
    /// store + the in-NE engine. Returns `nil` when it can't be built (no
    /// App-Group store) — the caller replies a typed failure in that case.
    ///
    /// SINGLE RUNTIME + NEW CONTROL CHANNEL: the bounded `[0xF5 0x02]`
    /// node-service control channel is a SEPARATE, parallel architecture from
    /// the legacy `ProxyRequest` IPC (which the app's `ProxyRnsBackend` uses,
    /// and which `dispatchPython` routes to `PythonNodeEngine`). The PRODUCTION
    /// message send goes through that `ProxyRequest` path - it is NOT routed
    /// through this node owner. This owner is the node-contract "first vertical
    /// slice" (contracts 6/6.5/15): a separate durable store + versioned
    /// control framing with a pluggable engine, being brought up incrementally.
    ///
    /// Until `PythonNodeEngine` gets its own `NodeEngine` conformance (a separate
    /// increment - the engine adapter is a deliberate black box that must not
    /// redefine app behavior; wiring it requires the adapter plus the admission /
    /// execution recovery and app-facade integration, not a one-line swap), the
    /// owner runs the engine-agnostic fail-closed `StubEngine`. That is the
    /// correct, honest state for the slice: the channel is reachable, the
    /// durable store + admission ledger work, and a command is COMMITTED as a
    /// typed rejection at the capability gate rather than referencing the
    /// removed C++ node. The DEBUG `test-node-send` deep link is the device
    /// plumbing test for THIS channel; while it runs on `StubEngine` it is
    /// EXPECTED to log a committed rejection - that is the signal the
    /// framing/store/admission path works end-to-end up to the engine gate,
    /// not a regression in the (separate, working) production send path.
    private func nodeOwnerIfNeeded() -> NodeOwner? {
        if let existing = nodeOwner { return existing }
        guard let storeURL = AppGroupPaths.nodeServiceStoreURL(),
              let store = try? NodeStore(config: .file(storeURL.path)) else {
            return nil
        }
        let owner = NodeOwner(store: store, engine: StubEngine())
        self.nodeOwner = owner
        return owner
    }

    // MARK: - Track A5b — Model B app→NE IPC dispatch

    /// Decode a `ProxyRequest` envelope and dispatch it to the in-NE Python RNS
    /// engine, replying through `completionHandler` with an encoded
    /// `ProxyResponse`. Only called from `handleAppMessage` once the magic
    /// prefix has matched.
    ///
    /// SINGLE RUNTIME: the engine is the in-NE Python RNS node
    /// (`PythonNodeEngine`), which drives `rns_bridge.py` through the embedded
    /// CPython. The abandoned C++ microReticulum node (`NEReticulumNode`) is no
    /// longer the runtime. If the engine isn't ready (CPython not up, or the
    /// app hasn't created a shared identity yet) the op replies `.unsupported`
    /// so the app degrades + retries gracefully.
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

        Task {
            let response = await NodeCommandDispatcher.dispatch(request)
            completionHandler?(ProxyIPC.encodeResponse(response))
        }
    }

    /// Route a decoded `ProxyRequest` to the in-NE Python RNS engine and build
    /// its `ProxyResponse`. `nonisolated`/`static` so it can be awaited from the
    /// detached `Task` above without capturing `self`. Every op is a JSON call
    /// into `rns_bridge` (via `PythonNodeEngine`); the Swift side maps the Python
    /// result JSON onto the `Proxy*` wire types the app decodes.
    override func sleep(completionHandler: @escaping () -> Void) {
        ExtensionDiagLog.log("sleep")
        completionHandler()
    }

    override func wake() {
        ExtensionDiagLog.log("wake")
        // Model B: the in-NE node owns the relay and its `TCPInterface`
        // self-reconnects, so there's nothing to re-apply on wake.
    }
}
