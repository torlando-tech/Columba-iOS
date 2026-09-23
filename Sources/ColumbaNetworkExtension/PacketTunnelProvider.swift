//
//  PacketTunnelProvider.swift
//  ColumbaNetworkExtension
//
//  NEPacketTunnelProvider host for the Model B in-NE Reticulum + LXMF node.
//  Model B is the SOLE architecture on the build that compiles the NE in
//  (ENABLE_NETWORK_EXTENSION ⇔ COLUMBA_BACKEND_SWIFT): the extension exists
//  solely to own and keep alive `NEReticulumNode` — the background LXMF
//  delivery path — while the main app is backgrounded. It carries NO raw-frame
//  forwarding: the node owns its own TCP relay interface + the AppGroupBridge,
//  and the app→NE send path is the `ProxyRequest`/`ProxyResponse` IPC handled in
//  `handleAppMessage` below.
//
//  (The earlier "Model A" PoC dumb-pipe — NWConnection TCP/Auto frame forwarding
//  over a shared HDLC queue, with an NWPathMonitor + a Darwin config-change
//  observer + exponential reconnect backoff — was removed once Model B became the
//  only architecture. See git history if that raw-relay code is ever needed.)
//

import Foundation
import Network
import NetworkExtension
import ColumbaNode

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
    /// `StubEngine`; the control channel stays reachable + honest, and the swap
    /// to the real engine is a one-line change in `nodeOwnerIfNeeded`.
    private var nodeOwner: NodeOwner?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ExtensionDiagLog.log("startTunnel called")

        // SINGLE RUNTIME: Python RNS is the only Reticulum runtime in the NE.
        // Initialize CPython here (non-blocking - it must never gate tunnel
        // bring-up). The actual node is brought up lazily when the app's first
        // `.start` IPC arrives (dispatchPython → NEPythonRNS.start), which loads
        // the shared identity + the app-written shared config. Until then the
        // engine is ready-but-not-running, and `.start` replies `.unsupported`
        // (or brings the node up) accordingly.
        Task {
            switch NEPythonRuntime.shared.start() {
            case .success:
                ExtensionDiagLog.log("[NE-PY-RNS] python ready (node starts on first .start IPC)")
            case .failure(let err):
                ExtensionDiagLog.log("[NE-PY-RNS] init failed: \(err.localizedDescription)")
            }
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

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ExtensionDiagLog.log("stopTunnel reason=\(reason.rawValue)")

        // Track C3: tear down the in-NE node. Stopping the node drops its TCP
        // relay interface + AppGroupBridge. Fire-and-forget — teardown is
        // best-effort and the completion handler must not block on it.
        // Also release the node owner (releases its shared NodeStore connection;
        // the store is durable WAL, so a clean close here is safe).
        // SINGLE RUNTIME: tear down the in-NE Python RNS engine. Stopping it
        // drops the node's transport + router. Fire-and-forget - teardown is
        // best-effort and the completion handler must not block on it.
        Task {
            NEPythonRNS.shared.stop()
            nodeOwner = nil
        }

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
    /// SINGLE RUNTIME: the bounded `[0xF5 0x02]` control channel is a SEPARATE
    /// seam from the legacy `ProxyRequest` IPC (which the app's
    /// `ProxyRnsBackend` uses, and which `dispatchPython` routes to
    /// `NEPythonRNS`). Until the Python RNS engine gets its own `NodeEngine`
    /// conformance, the owner runs the engine-agnostic fail-closed `StubEngine`
    /// so the control channel stays reachable + honest rather than referencing
    /// the removed C++ node.
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
    /// (`NEPythonRNS`), which drives `rns_bridge.py` through the embedded
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
            let response = await Self.dispatchPython(request)
            completionHandler?(ProxyIPC.encodeResponse(response))
        }
    }

    /// Route a decoded `ProxyRequest` to the in-NE Python RNS engine and build
    /// its `ProxyResponse`. `nonisolated`/`static` so it can be awaited from the
    /// detached `Task` above without capturing `self`. Every op is a JSON call
    /// into `rns_bridge` (via `NEPythonRNS`); the Swift side maps the Python
    /// result JSON onto the `Proxy*` wire types the app decodes.
    private static func dispatchPython(_ request: ProxyRequest) async -> ProxyResponse {
        let engine = NEPythonRNS.shared
        switch request {
        case .start(let displayName):
            // Bring the Python RNS node up. The engine loads the shared identity
            // + the app-written shared config itself. No identity yet ⇒ nil ⇒
            // `.unsupported` (the app retries until the app creates one).
            guard let localInfoJSON = engine.start(displayName: displayName) else {
                return .unsupported
            }
            return .ok(Self.mapLocalInfo(localInfoJSON))

        case .stop:
            engine.stop()
            return .ok(nil)

        case .announce(let displayName):
            guard let res = engine.announce(displayName: displayName) else { return .ok(try? JSONEncoder().encode(false)) }
            let ok = (res.object(forKey: "ok") as? Bool) ?? false
            return .ok(try? JSONEncoder().encode(ok))

        case .announceTelephony(let displayName):
            guard let res = engine.announceTelephony(displayName: displayName) else { return .ok(try? JSONEncoder().encode(false)) }
            let ok = (res.object(forKey: "ok") as? Bool) ?? false
            return .ok(try? JSONEncoder().encode(ok))

        case .statusSnapshot:
            // rns_bridge.status() returns the exact snake_case shape the app's
            // StatusSnapshot decodes (started / interfaces / *_table_size), so
            // forward its JSON directly.
            guard let res = engine.status() else { return .ok(nil) }
            return .ok(res.data(using: .utf8))

        case .heardAnnounces:
            // rns_bridge.drain_events() returns the event queue (snake_case
            // keys); keep the announce events and map them onto the
            // [ProxyHeardAnnounce] the app's poller decodes.
            guard let events = engine.drainEvents() else { return .ok(try? JSONEncoder().encode([ProxyHeardAnnounce]())) }
            let announces = events.compactMap { Self.mapHeardAnnounce($0) }
            return .ok(try? JSONEncoder().encode(announces))

        case .bleConnections:
            // BLE/RNode radio state lives in the app process (CoreBluetooth);
            // the NE Python engine does not own the radio in this slice. The
            // app's BLE screen degrades to empty.
            return .ok(nil)

        case .persist:
            guard let res = engine.persist() else { return .error("persist failed") }
            let ok = (res.object(forKey: "ok") as? Bool) ?? true
            return ok ? .ok(nil) : .error("persist failed")

        case .registeredDestinationHashes:
            // The delivery destination hash (the only destination the node
            // registers), from the local info. Empty when the node isn't up.
            if let localInfoJSON = engine.localInfo(),
               let obj = jsonObj(localInfoJSON),
               let dest = obj["destination_hash"] as? String, !dest.isEmpty {
                return .ok(try? JSONEncoder().encode([dest]))
            }
            return .ok(try? JSONEncoder().encode([String]()))

        case .lxmfSend(let destHashHex, let content, let method, let fieldsData):
            guard let res = engine.lxmfSend(destHashHex: destHashHex, content: content, method: method, fieldsHex: hexOf(fieldsData)) else {
                return .ok(try? JSONEncoder().encode(ProxySendOutcome(kind: .other, detail: "send dispatch failed")))
            }
            let outcome = Self.mapSendOutcome(res)
            return .ok(try? JSONEncoder().encode(outcome))

        case .nomadnetFetch:
            // The browser fetch is not wired to the NE Python engine in this
            // slice; reply a typed failure the app surfaces (not a crash).
            return .error("nomadnet fetch not available in the NE python engine yet")
        }
    }

    // MARK: - Python result -> Proxy* wire-type mappers

    /// Map the `rns_bridge.start` / `local_info` JSON (`{identity_hash,
    /// destination_hash}`) onto `ProxyLocalInfo` (`{identityHash, destinationHash}`).
    private static func mapLocalInfo(_ json: String) -> Data? {
        guard let obj = jsonObj(json),
              let ih = obj["identity_hash"] as? String,
              let dh = obj["destination_hash"] as? String else { return nil }
        return try? JSONEncoder().encode(ProxyLocalInfo(identityHash: ih, destinationHash: dh))
    }

    /// Map one `rns_bridge` announce event (snake_case keys) onto
    /// `ProxyHeardAnnounce` (camelCase). Returns nil for non-announce events.
    private static func mapHeardAnnounce(_ event: [String: Any]) -> ProxyHeardAnnounce? {
        guard (event["kind"] as? String) == "announce" else { return nil }
        return ProxyHeardAnnounce(
            destHashHex: event["dest_hash"] as? String ?? "",
            appDataHex: event["app_data"] as? String ?? "",
            aspect: event["aspect"] as? String ?? "",
            publicKeysHex: event["public_keys"] as? String ?? "",
            interfaceName: event["interface_name"] as? String ?? "",
            hops: event["hops"] as? Int ?? 0,
            timestamp: event["t"] as? Double ?? 0
        )
    }

    /// Map the `rns_bridge.send_opportunistic` result onto `ProxySendOutcome`.
    /// The result-reason mapping is contract-significant: `queued` is a committed
    /// send, `requesting-path` is durable + resumable (NOT a committed failure).
    private static func mapSendOutcome(_ res: [String: Any]) -> ProxySendOutcome {
        guard res["ok"] as? Bool == true else {
            switch res["reason"] as? String {
            case "requesting-path": return ProxySendOutcome(kind: .requestingPath)
            case "bad-hash":        return ProxySendOutcome(kind: .badHash)
            case "not-started":     return ProxySendOutcome(kind: .notStarted)
            case let other?:        return ProxySendOutcome(kind: .other, detail: other)
            case nil:               return ProxySendOutcome(kind: .other, detail: "send failed")
            }
        }
        // ok == true ⇒ a committed send.
        return ProxySendOutcome(kind: .queued, detail: res["message_hash"] as? String)
    }

    private static func jsonObj(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hexOf(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

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
