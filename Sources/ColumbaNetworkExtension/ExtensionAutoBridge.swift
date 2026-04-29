//
//  ExtensionAutoBridge.swift
//  ColumbaNetworkExtension
//
//  Runs `ReticulumSwift.AutoInterface` inside the extension so
//  AutoInterface peer discovery (multicast HELLO with the correct
//  `ff12:0:…` group derivation) and per-peer unicast data delivery
//  keep working while the main app is backgrounded.
//
//  Inbound: every received packet — whether it lands on the parent
//  AutoInterface or one of the spawned `AutoInterfacePeer`
//  sub-interfaces — is funneled into `SharedFrameQueue` with the
//  Auto tag, then a Darwin notification wakes the app's
//  `ExtensionFrameReader` to drain it.
//
//  Outbound: when the app's AutoInterface (in tunnel mode) hands
//  raw bytes to its outbound hook, `PacketTunnelProvider` forwards
//  them via `send(_:)` here — which calls `AutoInterface.send(_:)`
//  on the extension-side instance, which does its own per-peer
//  fan-out.
//

import Foundation
import ReticulumSwift

/// Bridge between the extension's `AutoInterface` and the
/// `SharedFrameQueue`. Owns the AutoInterface lifecycle and
/// forwards inbound packets from every peer sub-interface to the
/// shared queue.
final class ExtensionAutoBridge: NSObject, InterfaceDelegate, @unchecked Sendable {

    // MARK: - Properties

    private let frameQueue: SharedFrameQueue
    private let postNotif: () -> Void
    private var autoInterface: AutoInterface?

    /// Currently-applied group id; nil when stopped. Used by
    /// `PacketTunnelProvider` to decide whether a config update
    /// requires a restart.
    private(set) var groupId: String?

    // MARK: - Initialization

    init(frameQueue: SharedFrameQueue, postNotif: @escaping () -> Void) {
        self.frameQueue = frameQueue
        self.postNotif = postNotif
    }

    // MARK: - Lifecycle

    /// Start a fresh AutoInterface for the given group id.
    func start(groupId: String) {
        Task {
            await self.startAsync(groupId: groupId)
        }
    }

    /// Stop and tear down the AutoInterface.
    func stop() {
        Task {
            await self.stopAsync()
        }
    }

    /// Forward outbound bytes from the app to the extension-side
    /// AutoInterface, which fans them out per-peer.
    func send(_ data: Data) {
        Task {
            guard let auto = self.autoInterface else {
                ExtensionDiagLog.log("[EXT/Auto] TX dropped \(data.count)B — autoInterface nil")
                return
            }
            do {
                try await auto.send(data)
                ExtensionDiagLog.log("[EXT/Auto] TX \(data.count)B fanned out")
            } catch {
                ExtensionDiagLog.log("[EXT/Auto] TX \(data.count)B failed: \(error)")
            }
        }
    }

    // MARK: - InterfaceDelegate

    func interface(id: String, didChangeState state: InterfaceState) {
        ExtensionDiagLog.log("[EXT/Auto] iface \(id) state: \(state)")
    }

    func interface(id: String, didReceivePacket data: Data) {
        // Funnel packets received on either the parent AutoInterface
        // or any of its per-peer sub-interfaces into the shared
        // queue with the Auto tag. The app's `ExtensionFrameReader`
        // re-injects them via `transport.handleReceivedData(from:)`,
        // so the transport sees the same byte stream the app's own
        // AutoInterface would have produced — just one process over.
        ExtensionDiagLog.log("[EXT/Auto] RX \(data.count)B from \(id)")
        frameQueue.append(frame: data, interfaceTag: FrameInterfaceTag.auto.rawValue)
        postNotif()
    }

    func interface(id: String, didFailWithError error: Error) {
        ExtensionDiagLog.log("[EXT/Auto] iface \(id) failed: \(error)")
    }

    // MARK: - Private

    private func startAsync(groupId: String) async {
        await stopAsync()

        let config = InterfaceConfig(
            id: "ext-auto",
            name: "ext-auto",
            type: .autoInterface,
            enabled: true,
            mode: .full,
            host: groupId,
            port: 0
        )
        let auto = AutoInterface(config: config)
        await auto.setDelegate(self)

        // Each spawned `AutoInterfacePeer` is a distinct interface
        // with its own delegate chain — we have to set our delegate
        // on every peer as it appears so its received packets reach
        // the SharedFrameQueue.
        await auto.setPeerCallbacks(
            onPeerAdded: { [weak self] (peer: AutoInterfacePeer) in
                guard let self else { return }
                Task {
                    let pid = await peer.id
                    ExtensionDiagLog.log("[EXT/Auto] peer added: \(pid)")
                    await peer.setDelegate(self)
                }
            },
            onPeerRemoved: { (peerId: String) in
                ExtensionDiagLog.log("[EXT/Auto] peer removed: \(peerId)")
            }
        )

        do {
            try await auto.connect()
            self.autoInterface = auto
            self.groupId = groupId
            ExtensionDiagLog.log("[EXT/Auto] AutoInterface started for groupId=\(groupId)")
        } catch {
            ExtensionDiagLog.log("[EXT/Auto] AutoInterface connect failed: \(error)")
        }
    }

    private func stopAsync() async {
        guard let auto = autoInterface else { return }
        await auto.disconnect()
        autoInterface = nil
        groupId = nil
        ExtensionDiagLog.log("[EXT/Auto] AutoInterface stopped")
    }
}
