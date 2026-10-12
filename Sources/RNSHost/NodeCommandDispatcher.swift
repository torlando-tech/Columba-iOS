import Foundation
import SwiftBLEBridge

/// The single command implementation used by both process hosts.
enum NodeCommandDispatcher {
    private static func bridgeResponse(_ json: String?) -> ProxyResponse {
        guard let json, let data = json.data(using: .utf8) else { return .error("node command failed") }
        return .ok(data)
    }
    static func dispatch(_ request: ProxyRequest, host: NodeHostingMode = .networkExtension) async -> ProxyResponse {
        let engine = PythonNodeEngine.shared
        switch request {
        case .resolvePath(let hash, let timeout):
            return bridgeResponse(engine.call("resolve_path", kwargs: ["dest_hash_hex": hash, "timeout_seconds": timeout]))
        case .discovery:
            guard let json = engine.call("discovery_json", kwargs: [:]),
                  let encoded = json.data(using: .utf8),
                  let string = try? JSONDecoder().decode(String.self, from: encoded) else { return .error("discovery failed") }
            return .ok(string.data(using: .utf8))
        case .setPropagationNode(let hash, let cost):
            return bridgeResponse(engine.call("set_propagation_node", kwargs: ["dest_hash_hex": hash, "stamp_cost": cost]))
        case .propagationSync(let timeout):
            return bridgeResponse(engine.call("propagation_sync", kwargs: ["timeout": timeout]))
        case .cancelPropagationSync:
            return bridgeResponse(engine.call("cancel_propagation_sync", kwargs: [:]))
        case .incomingMessageLimit(let limit):
            return bridgeResponse(engine.call("set_incoming_message_size_limit_kb", kwargs: ["limit_kb": limit]))
        case .rememberPeer(let hash, let key):
            return bridgeResponse(engine.call("remember_peer_identity", kwargs: ["dest_hash_hex": hash, "public_key_hex": key]))
        case .start(let displayName):
            // Bring the Python RNS node up. The engine loads the shared identity
            // + the app-written shared config itself. No identity yet ⇒ nil ⇒
            // `.unsupported` (the app retries until the app creates one).
            // Persist the display name so the NE can auto-restart the node
            // after a relaunch (e.g. tunnel session reconnect) without waiting
            // for the app to re-send .start.
            UserDefaults(suiteName: "group.network.columba.Columba")?
                .set(displayName, forKey: "rnsLastDisplayName")
            guard let localInfoJSON = engine.start(displayName: displayName, host: host) else {
                return .unsupported
            }
            return .ok(Self.mapLocalInfo(localInfoJSON))

        case .stop:
            guard engine.stop() else { return .error("node stop failed") }
            // An explicit .stop means the node should stay down. Clear the
            // auto-start lever so a tunnel relaunch (startTunnel) does NOT
            // bring the node back up without a fresh .start (Issue 7). The next
            // explicit .start re-persists the display name.
            UserDefaults(suiteName: "group.network.columba.Columba")?
                .removeObject(forKey: "rnsLastDisplayName")
            return .ok(nil)

        case .announce(let displayName):
            guard let res = engine.announce(displayName: displayName) else {
                #if DEBUG
                ExtensionDiagLog.log("[NE-DISP] announce: engine returned nil")
                #endif
                return .ok(try? JSONEncoder().encode(false))
            }
            let ok = (res["ok"] as? Bool) ?? false
            if !ok {
                #if DEBUG
                ExtensionDiagLog.log("[NE-DISP] announce ok=false reason=\(res["reason"] as? String ?? "?")")
                #endif
            }
            return .ok(try? JSONEncoder().encode(ok))

        case .announceTelephony(let displayName):
            guard let res = engine.announceTelephony(displayName: displayName) else {
                #if DEBUG
                ExtensionDiagLog.log("[NE-DISP] announceTelephony: engine returned nil")
                #endif
                return .ok(try? JSONEncoder().encode(false))
            }
            let ok = (res["ok"] as? Bool) ?? false
            if !ok {
                #if DEBUG
                ExtensionDiagLog.log("[NE-DISP] announceTelephony ok=false reason=\(res["reason"] as? String ?? "?")")
                #endif
            }
            return .ok(try? JSONEncoder().encode(ok))

        case .statusSnapshot:
            // rns_bridge.status() returns the exact snake_case shape the app's
            // StatusSnapshot decodes (started / interfaces / *_table_size), so
            // forward its JSON directly.
            guard let res = engine.status() else { return .ok(nil) }
            return .ok(res.data(using: .utf8))

        case .attachInterface(let name):
            // Hot-attach an interface to the live NE node without a restart
            // (RNS 1.5.5). The app rewrote the shared config first, so the NE
            // re-reads the fresh [[name]] section. rns_bridge returns {ok, reason};
            // forward the ok Bool (a nil engine result = bridge-level failure →
            // false, which the app treats as a hot-apply miss and falls back to a
            // restart).
            guard let res = engine.attachInterface(name: name) else {
                return .ok(try? JSONEncoder().encode(false))
            }
            let ok = (res["ok"] as? Bool) ?? false
            return .ok(try? JSONEncoder().encode(ok))

        case .detachInterface(let name):
            // Hot-detach an interface from the live NE node without a restart
            // (RNS 1.5.5, which tears the interface's spawned children down too).
            guard let res = engine.detachInterface(name: name) else {
                return .ok(try? JSONEncoder().encode(false))
            }
            let ok = (res["ok"] as? Bool) ?? false
            return .ok(try? JSONEncoder().encode(ok))

        case .heardAnnounces:
            // rns_bridge.drain_events() returns the event queue (snake_case
            // keys); keep the announce events and map them onto the
            // [ProxyHeardAnnounce] the app's poller decodes.
            guard let events = engine.drainEvents() else { return .ok(try? JSONEncoder().encode([ProxyHeardAnnounce]())) }
            let announces = events.compactMap { Self.mapHeardAnnounce($0) }
            return .ok(try? JSONEncoder().encode(announces))

        case .drainEvents:
            // The Model B event bridge: read a bounded page of the queue (inbound, delivery,
            // state, link, announce) and map every event onto ProxyEvent so the
            // app's proxy poller can re-emit each as a BackendEvent. (The legacy
            // .heardAnnounces op above only maps announces and discards the rest;
            // this op carries everything.)
            guard let events = engine.drainEvents() else { return .ok(try? JSONEncoder().encode([ProxyEvent]())) }
            let mapped = events.map { Self.mapProxyEvent($0) }
            return .ok(try? JSONEncoder().encode(mapped))

        case .ackInbox(let maxSeq):
            // Advance the durable-inbox cursor (Contract §5). `drain_inbox` is a
            // bounded, non-destructive read; the app acks the highest `seq` it has
            // processed, and the NE deletes only rows at or below the cursor.
            // Unacked rows survive a lost drain reply / app death and are
            // re-returned on the next drain (at-least-once; announce dedup in the
            // app makes re-delivery idempotent).
            let acknowledged = engine.ackInbox(maxSeq: maxSeq)
            return .ok(try? JSONEncoder().encode(acknowledged))

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

        case .lxmfSend(let destHashHex, let content, let method, let fieldsData, let sendId, let fallback):
            // P1 #6: thread the app's stable sendId into the NE so the engine
            // dedups (a lost live reply + outbox replay can't double-send).
            guard let res = engine.lxmfSend(destHashHex: destHashHex, content: content, method: method, fieldsHex: hexOf(fieldsData), sendId: sendId, failureFallbackMethod: fallback) else {
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
            publicKeyHex: e["public_key"] as? String,
            seq: e["seq"] as? Int
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
        // ok == true ⇒ a committed send. Surface a degraded dedup guard: the NE
        // sets id_persisted=false when it could not persist the sendId (file
        // write failure). The message went out, so the outcome is still .queued
        // (flipping to failure would make the app re-enqueue and double-send,
        // which is strictly worse); the flag lets the app log the degradation.
        let idPersisted = res["id_persisted"] as? Bool
        return ProxySendOutcome(kind: .queued, detail: res["message_hash"] as? String, idPersisted: idPersisted)
    }

    private static func jsonObj(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func hexOf(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

}
