//
//  PacketTunnelProvider.swift
//  ColumbaNetworkExtension
//
//  NEPacketTunnelProvider host for the Model B in-NE Reticulum + LXMF node.
//  Model B is the SOLE architecture on the build that compiles the NE in
//  (ENABLE_NETWORK_EXTENSION ⇔ COLUMBA_BACKEND_SWIFT): the extension exists
//  solely to own and keep alive the in-NE Python RNS node (`NEPythonRNS` over
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
    /// `StubEngine`; the control channel stays reachable + honest, and the swap
    /// to the real engine is a one-line change in `nodeOwnerIfNeeded`.
    private var nodeOwner: NodeOwner?

    // MARK: - Inbound banner (Model B)

    /// Darwin observer token for the NE-published inbound-banner ping. The NE's
    /// Python RNS writes a small `inbound-banner.json` into the shared per-identity
    /// dir + posts `network.columba.inboundBanner`; this observer reads the payload
    /// and posts the user-facing `UNUserNotification` from the NE process. The NE
    /// (not the app) posts it so the banner shows even while the app is suspended
    /// or terminated - the tunnel keeps the NE process alive. Registered on
    /// `startTunnel`, removed on `stopTunnel`.
    private var bannerObserverToken: UnsafeMutableRawPointer?

    /// Register the inbound-banner Darwin observer. Idempotent (guards against a
    /// double `startTunnel`).
    private func startInboundBannerObserver() {
        if bannerObserverToken != nil { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let token = Unmanaged.passUnretained(self).toOpaque()
        let name = "network.columba.inboundBanner"
        CFNotificationCenterAddObserver(
            center,
            token,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let self_ = Unmanaged<PacketTunnelProvider>.fromOpaque(observer).takeUnretainedValue()
                self_.postInboundBanner()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
        bannerObserverToken = token
        ExtensionDiagLog.log("inbound banner observer registered")
    }

    private func stopInboundBannerObserver() {
        if let token = bannerObserverToken {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                token,
                CFNotificationName("network.columba.inboundBanner" as CFString),
                nil
            )
            bannerObserverToken = nil
        }
    }

    /// Read the banner payload the NE's Python wrote, and post a local
    /// `UNUserNotification`. Mirrors the app's `NotificationService` posture: honor
    /// the host's authorization (the app owns the prompt; the NE never requests
    /// auth), show a brief preview, thread by sender. Best-effort - a failure
    /// (e.g. not authorized) just logs; the message is still persisted to the
    /// shared store + unread, so it surfaces on next open.
    private func postInboundBanner() {
        // Resolve the shared per-identity dir (where the Python wrote the payload).
        let configDir = NEPythonRNS.sharedConfigDir()
        let payloadPath = (configDir as NSString).appendingPathComponent("inbound-banner.json")
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)) else {
            ExtensionDiagLog.log("inbound banner: no payload")
            return
        }
        struct Banner: Decodable {
            let senderPrefix: String
            let displayName: String?
            let preview: String
            let threadId: String
        }
        let banner = (try? JSONDecoder().decode(Banner.self, from: raw))
        let center = UNUserNotificationCenter.current()
        Task {
            // Honor the host's authorization only (the app owns the prompt; we never
            // request it from the NE).
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else {
                ExtensionDiagLog.log("inbound banner: not authorized - skipping")
                return
            }
            let title = banner?.displayName ?? "Peer \(banner?.senderPrefix ?? "0000")"
            let previewText = banner?.preview ?? ""
            let body = previewText.isEmpty ? "New message" : previewText
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = banner?.threadId ?? UUID().uuidString
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "columba.inbound." + UUID().uuidString,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                ExtensionDiagLog.log("inbound banner posted from=\(banner?.senderPrefix ?? "??")")
            } catch {
                ExtensionDiagLog.log("inbound banner failed: \(error.localizedDescription)")
            }
        }
    }

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
                // Auto-restart: if the app previously started a node (persisted
                // display name + shared config dir exist), bring it up now.
                // This covers the tunnel-session-reconnect relaunch case where
                // the in-process RNS restart already ran but the NE was killed
                // before the app re-sent .start. Idempotent: if the app sends
                // .start later, engine.start() is a no-op restart.
                let defaults = UserDefaults(suiteName: "group.network.columba.Columba")
                if let name = defaults?.string(forKey: "rnsLastDisplayName") {
                    let configDir = (NEPythonRNS.sharedConfigDir() as NSString).appendingPathComponent("config")
                    if FileManager.default.fileExists(atPath: configDir) {
                        ExtensionDiagLog.log("[NE-PY-RNS] auto-start: config found, starting node")
                        if NEPythonRNS.shared.start(displayName: name) != nil {
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
        NEPythonBridgeHook.wireToPython()
        NEBLECallbackInvoker.install()

        // Set up dummy tunnel settings (required by NEPacketTunnelProvider)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["169.254.1.1"], subnetMasks: ["255.255.255.255"])
        settings.mtu = 1500

        // Model B: listen for the NE's inbound-banner ping so the user gets a
        // banner even while the app is suspended / terminated (the tunnel keeps
        // this process alive). Independent of tunnel-settings bring-up.
        startInboundBannerObserver()

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

        // Drop the inbound-banner observer (no more banners once the node is down).
        stopInboundBannerObserver()

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
    /// and which `dispatchPython` routes to `NEPythonRNS`). The PRODUCTION
    /// message send goes through that `ProxyRequest` path - it is NOT routed
    /// through this node owner. This owner is the node-contract "first vertical
    /// slice" (contracts 6/6.5/15): a separate durable store + versioned
    /// control framing with a pluggable engine, being brought up incrementally.
    ///
    /// Until `NEPythonRNS` gets its own `NodeEngine` conformance (a separate
    /// increment - the engine adapter is a deliberate black box that must not
    /// redefine app behavior, and wiring it is a one-line change here), the
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
            // Persist the display name so the NE can auto-restart the node
            // after a relaunch (e.g. tunnel session reconnect) without waiting
            // for the app to re-send .start.
            UserDefaults(suiteName: "group.network.columba.Columba")?
                .set(displayName, forKey: "rnsLastDisplayName")
            guard let localInfoJSON = engine.start(displayName: displayName) else {
                return .unsupported
            }
            return .ok(Self.mapLocalInfo(localInfoJSON))

        case .stop:
            engine.stop()
            return .ok(nil)

        case .announce(let displayName):
            guard let res = engine.announce(displayName: displayName) else { return .ok(try? JSONEncoder().encode(false)) }
            let ok = (res["ok"] as? Bool) ?? false
            return .ok(try? JSONEncoder().encode(ok))

        case .announceTelephony(let displayName):
            guard let res = engine.announceTelephony(displayName: displayName) else { return .ok(try? JSONEncoder().encode(false)) }
            let ok = (res["ok"] as? Bool) ?? false
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

        case .drainEvents:
            // The Model B event bridge: drain the FULL queue (inbound, delivery,
            // state, link, announce) and map every event onto ProxyEvent so the
            // app's proxy poller can re-emit each as a BackendEvent. (The legacy
            // .heardAnnounces op above only maps announces and discards the rest;
            // this op carries everything.)
            guard let events = engine.drainEvents() else { return .ok(try? JSONEncoder().encode([ProxyEvent]())) }
            let mapped = events.map { Self.mapProxyEvent($0) }
            return .ok(try? JSONEncoder().encode(mapped))

        case .bleConnections:
            // Phase 2: the mesh CoreBluetooth radio now runs IN-PROCESS in the
            // NE (SwiftBLEBridge, linked into this target). The app's BLE
            // connections screen round-trips this, so read the live peer
            // details from the in-extension radio and map them onto the
            // [BLEPeerSnapshot] the app's `ProxyRnsBackend.bleConnections()`
            // decodes. Group by identity (a peer bonded via BOTH central and
            // peripheral roles yields two entries; prefer the peripheral path
            // and borrow the central-side RSSI, mirroring the app-side mapping).
            let details = SwiftBLEBridge.shared.getConnectionDetails()
            var rep: [String: BleConnectionDetails] = [:]
            var rssiByIdentity: [String: Int] = [:]
            var earliestConnectedAt: [String: Date] = [:]
            for d in details {
                guard let id = d.identityHashHex else { continue }
                if let r = d.rssi { rssiByIdentity[id] = r }
                earliestConnectedAt[id] = min(earliestConnectedAt[id] ?? d.connectedAt, d.connectedAt)
                if let existing = rep[id] {
                    if d.role == .peripheral && existing.role != .peripheral {
                        rep[id] = d
                    } else if d.mtu > existing.mtu {
                        rep[id] = d
                    }
                } else {
                    rep[id] = d
                }
            }
            let snapshots: [BLEPeerSnapshot] = rep.values.map { d in
                let id = d.identityHashHex ?? d.address
                let rssi = d.rssi ?? rssiByIdentity[id]
                return BLEPeerSnapshot(
                    identityHash: id,
                    isOutgoing: d.role == .central,
                    rssi: rssi ?? 0,
                    mtu: d.mtu,
                    connectedAt: earliestConnectedAt[id] ?? d.connectedAt,
                    lastActivity: d.lastActivity,
                    bytesSent: 0,
                    bytesReceived: 0,
                    packetsSent: 0,
                    packetsReceived: 0
                )
            }
            return .ok(try? JSONEncoder().encode(snapshots))

        case .bleDisconnect(let identityHashHex):
            // The NE owns the radio in Model B, so the app resolves identity to
            // a link and asks the in-extension radio to drop it. Return true
            // only when a connected peer with that identity existed.
            if let address = SwiftBLEBridge.shared.getPeerAddress(identityHashHex: identityHashHex) {
                SwiftBLEBridge.shared.disconnect(address: address)
                return .ok(try? JSONEncoder().encode(true))
            }
            return .ok(try? JSONEncoder().encode(false))

        case .persist:
            guard let res = engine.persist() else { return .error("persist failed") }
            let ok = (res["ok"] as? Bool) ?? true
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

        case .nomadnetFetch(let destHashHex, let path, let timeoutSeconds, let formFields):
            // One-shot NomadNet page fetch: run the synchronous RNS-Link request
            // in the NE Python engine (nomadnet_fetch_op base64-encodes the page
            // bytes so they survive the callBridge JSON round-trip) and map the
            // result onto the ProxyNomadNetOutcome the app's proxy decodes. A
            // bridge-level failure (NE not running / node not up) degrades to a
            // typed `.notStarted`/`.unknown` outcome, matching the app's
            // "stopped backend" contract.
            guard let res = engine.nomadnetFetch(destHashHex: destHashHex, path: path, timeout: timeoutSeconds, formFields: formFields) else {
                return .ok(try? JSONEncoder().encode(ProxyNomadNetOutcome(ok: false, status: "not-started", data: Data(), contentType: "")))
            }
            let data = Data(base64Encoded: (res["data_b64"] as? String) ?? "") ?? Data()
            let outcome = ProxyNomadNetOutcome(
                ok: (res["ok"] as? Bool) ?? false,
                status: (res["status"] as? String) ?? "unknown",
                data: data,
                contentType: (res["content_type"] as? String) ?? ""
            )
            return .ok(try? JSONEncoder().encode(outcome))

        case .openLink(let destHashHex, let aspect, let identityPublicKeyHex):
            // Open an outbound RNS.Link. The NE Python `open_link` performs a
            // bounded path request (up to ~10s) and returns the exact
            // `{ok, link_id, reason}` dict; forward it as a typed payload so
            // the app's `openLink` proxy decodes the same shape the Python
            // return carries. (A heterogeneous `[String: Value]` literal won't
            // type-check for JSONEncoder - encode a struct, mirroring `Banner`.)
            struct LinkOpen: Encodable {
                let ok: Bool
                let linkId: Int
                let reason: String
                enum CodingKeys: String, CodingKey { case ok; case linkId = "link_id"; case reason }
            }
            guard let res = engine.openLink(destHashHex: destHashHex, aspect: aspect, identityPublicKeyHex: identityPublicKeyHex) else {
                return .ok(try? JSONEncoder().encode(LinkOpen(ok: false, linkId: 0, reason: "not-started")))
            }
            return .ok(try? JSONEncoder().encode(LinkOpen(
                ok: (res["ok"] as? Bool) ?? false,
                linkId: (res["link_id"] as? Int) ?? 0,
                reason: (res["reason"] as? String) ?? ""
            )))

        case .linkSend(let linkId, let dataHex):
            // Send opaque bytes over an established link. Per-frame IPC; a
            // short deadline on the app keeps a wedged NE from hanging audio.
            guard let res = engine.linkSend(linkId: linkId, dataHex: dataHex) else {
                return .ok(try? JSONEncoder().encode(false))
            }
            return .ok(try? JSONEncoder().encode((res["ok"] as? Bool) ?? false))

        case .linkIdentify(let linkId):
            // Reveal our identity on the link (RNS LINKIDENTIFY).
            guard let res = engine.linkIdentify(linkId: linkId) else {
                return .ok(try? JSONEncoder().encode(false))
            }
            return .ok(try? JSONEncoder().encode((res["ok"] as? Bool) ?? false))

        case .linkTeardown(let linkId):
            // Tear down the link from our side.
            guard let res = engine.linkTeardown(linkId: linkId) else {
                return .ok(try? JSONEncoder().encode(false))
            }
            return .ok(try? JSONEncoder().encode((res["ok"] as? Bool) ?? false))
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

    /// Map one `rns_bridge` drained event (snake_case keys) onto a `ProxyEvent`,
    /// preserving every field the Python `_put` payload carries so the app's
    /// proxy can reconstruct the exact `BackendEvent`. Unlike `mapHeardAnnounce`
    /// (announce-only), this handles all kinds and keeps the rest optional.
    private static func mapProxyEvent(_ e: [String: Any]) -> ProxyEvent {
        ProxyEvent(
            kind: e["kind"] as? String ?? "",
            t: e["t"] as? Double ?? 0,
            // announce
            destHashHex: e["dest_hash"] as? String,
            appDataHex: e["app_data"] as? String,
            aspect: e["aspect"] as? String,
            publicKeysHex: e["public_keys"] as? String,
            interfaceName: e["interface_name"] as? String,
            hops: e["hops"] as? Int,
            // inbound
            sourceHashHex: e["source_hash"] as? String,
            messageHashHex: e["message_hash"] as? String,
            content: e["content"] as? String,
            title: e["title"] as? String,
            fieldsHex: e["fields_hex"] as? String,
            // shared (inbound + delivery)
            method: e["method"] as? String,
            // delivery
            state: e["state"] as? String,
            reason: e["reason"] as? String,
            // signal metrics (inbound)
            rssi: e["rssi"] as? Double,
            snr: e["snr"] as? Double,
            // link
            linkId: e["link_id"] as? Int,
            dataHex: e["data_hex"] as? String,
            identityHashHex: e["identity_hash"] as? String,
            inbound: e["inbound"] as? Bool,
            publicKeyHex: e["public_key"] as? String
        )
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
