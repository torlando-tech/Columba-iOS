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

class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Model B node

    /// The in-NE Reticulum + LXMF node — the LIVE background delivery path. It
    /// owns its own TCP relay interface (read from the shared App-Group config)
    /// and the AppGroupBridge, and services the app's `ProxyRequest` IPC.
    /// Constructed + started in `startTunnel`, torn down in `stopTunnel`; `nil`
    /// only before start / after stop. `NEReticulumNode.modelBNodeEnabled` is
    /// hardcoded `true` — the NE exists solely to host this node.
    private var reticulumNode: NEReticulumNode?

    // MARK: - Tunnel Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        ExtensionDiagLog.log("startTunnel called")

        // Construct + start the in-NE Reticulum + LXMF node (Track A5a + C3). It
        // owns its own TCP relay interface (read from the same App-Group config)
        // + the AppGroupBridge. `start()` is a clean no-op if the shared identity
        // isn't available yet.
        ExtensionDiagLog.log("startTunnel: Model B — in-NE node owns delivery")
        let node = NEReticulumNode()
        self.reticulumNode = node
        Task {
            do {
                _ = try await node.start()
            } catch {
                ExtensionDiagLog.log("startTunnel: NEReticulumNode.start failed: \(String(describing: error))")
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
        if let node = reticulumNode {
            reticulumNode = nil
            Task { await node.stop() }
        }

        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // ── Track A5b (Model B app→NE send path) ────────────────────────────────
        // The app talks to the NE node exclusively via `ProxyRequest` envelopes,
        // marked by a leading magic byte (`ProxyIPC.magic` = 0xF5). Decode + reply
        // with an encoded `ProxyResponse`. Any non-ProxyRequest message is ignored
        // (the PoC raw-frame forwarding it used to carry is gone).
        if ProxyIPC.isProxyRequest(messageData) {
            handleProxyRequest(messageData, completionHandler: completionHandler)
            return
        }
        completionHandler?(nil)
    }

    // MARK: - Track A5b — Model B app→NE IPC dispatch

    /// Decode a `ProxyRequest` envelope and dispatch it to the in-NE
    /// `NEReticulumNode`, replying through `completionHandler` with an encoded
    /// `ProxyResponse`. Only called from `handleAppMessage` once the magic prefix
    /// has matched. If the node isn't running (e.g. not yet started), every op
    /// replies `.unsupported` so the app degrades gracefully.
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
        // (not yet started): reply `.unsupported`.
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

        case .bleConnections:
            guard let json = await node.bleConnectionsJSONForIPC() else {
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
        // Model B: the in-NE node owns the relay and its `TCPInterface`
        // self-reconnects, so there's nothing to re-apply on wake.
    }
}
