//
//  NetworkStatusViewModel.swift
//  ColumbaApp
//
//  ViewModel for the Network Status screen.
//  Polls transport for all registered interfaces and exposes them as observable state.
//

import Foundation
import RNSAPI
import SwiftUI

// MARK: - Interface Info

/// Snapshot of a single interface for display in the Network Status screen.
struct InterfaceInfo: Identifiable {
    let id: String
    let name: String
    let type: String
    let online: Bool
    let state: InterfaceState
    let isAutoInterfacePeer: Bool
    let peerAddress: String?
    let lastErrorDescription: String?
}

// MARK: - Network Status ViewModel

/// ViewModel for the Network Status screen.
///
/// Polls ReticulumTransport every second to get a snapshot of all registered
/// interfaces, including AutoInterfacePeers, and exposes them as observable state.
@available(iOS 17.0, macOS 14.0, *)
@Observable
final class NetworkStatusViewModel {

    // MARK: - Dependencies

    private let appServices: AppServices

    // MARK: - Observable State

    /// All interfaces currently registered with transport.
    var interfaces: [InterfaceInfo] = []

    /// Whether Reticulum transport is initialized.
    var isInitialized: Bool = false

    /// Overall network status description.
    var networkStatus: String = "Not initialized"

    /// Number of active (online) interfaces.
    var activeCount: Int {
        interfaces.filter(\.online).count
    }

    // MARK: - Internal

    private var pollTask: Task<Void, Never>?

    // MARK: - Init

    init(appServices: AppServices) {
        self.appServices = appServices
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refresh() async {
        // Model B: the app's local transport is a Compat stub — the real interfaces
        // (relay, BLE mesh + peers) live in the NE. Read them over the proxy
        // `statusSnapshot` IPC instead of the empty/stale app transport.
        if BackendPreference.modelB {
            await refreshFromNE()
            return
        }

        // Read transport reference on MainActor
        let transport = await MainActor.run { appServices.transport }

        guard let transport = transport else {
            await MainActor.run {
                isInitialized = false
                networkStatus = "Transport not initialized"
                interfaces = []
            }
            return
        }

        // Await actor-isolated snapshots OFF main thread
        let snapshots = await transport.getInterfaceSnapshots()

        var infos: [InterfaceInfo] = []
        for snap in snapshots {
            let typeName: String
            if snap.isAutoInterfacePeer {
                typeName = "AutoInterfacePeer"
            } else if snap.isBLEPeerInterface {
                typeName = "BLEPeer"
            } else {
                switch snap.type {
                case .tcp: typeName = "TCPClient"
                case .udp: typeName = "UDP"
                case .i2p: typeName = "I2P"
                case .autoInterface: typeName = "AutoInterface"
                case .rnode: typeName = "RNode"
                case .ble: typeName = "BLE"
                case .multipeerConnectivity: typeName = "Multipeer"
                }
            }

            let isOnline: Bool
            switch snap.state {
            case .connected:
                isOnline = true
            default:
                isOnline = false
            }

            infos.append(InterfaceInfo(
                id: snap.id,
                name: snap.name,
                type: typeName,
                online: isOnline,
                state: snap.state,
                isAutoInterfacePeer: snap.isAutoInterfacePeer,
                peerAddress: snap.peerAddress,
                lastErrorDescription: snap.lastErrorDescription
            ))
        }

        // Batch all UI mutations into single MainActor.run
        let onlineCount = infos.filter(\.online).count
        await MainActor.run {
            isInitialized = true
            interfaces = infos

            if infos.isEmpty {
                networkStatus = "No interfaces"
            } else if onlineCount == infos.count {
                networkStatus = "All interfaces online"
            } else if onlineCount > 0 {
                networkStatus = "\(onlineCount)/\(infos.count) interfaces online"
            } else {
                networkStatus = "All interfaces offline"
            }
        }
    }

    /// Model B: read the NE's interfaces over the proxy `statusSnapshot` IPC and
    /// reconstruct the rows (the app's local transport is a Compat stub and never
    /// holds the relay / BLE mesh / BLE peers the NE actually runs).
    private func refreshFromNE() async {
        let backend = await MainActor.run { appServices.backend }
        guard let backend else {
            await MainActor.run {
                isInitialized = false
                networkStatus = "Backend not initialized"
                interfaces = []
            }
            return
        }
        guard let snap = await backend.statusSnapshot() else {
            await MainActor.run {
                isInitialized = false
                networkStatus = "Network Extension not running"
                interfaces = []
            }
            return
        }

        let infos: [InterfaceInfo] = snap.interfaces.map { iface in
            let isBLEPeer = iface.isBLEPeer ?? false
            let isAutoPeer = iface.isAutoPeer ?? false
            let typeName: String
            if isAutoPeer { typeName = "AutoInterfacePeer" }
            else if isBLEPeer { typeName = "BLEPeer" }
            else { typeName = Self.displayType(forRaw: iface.typeRaw) }
            let addr = (iface.peerAddress?.isEmpty == false) ? iface.peerAddress : nil
            let err = (iface.lastError?.isEmpty == false) ? iface.lastError : nil
            return InterfaceInfo(
                id: iface.sectionName,
                name: iface.name,
                type: typeName,
                online: iface.online,
                state: iface.online ? .connected : .disconnected,
                isAutoInterfacePeer: isAutoPeer,
                peerAddress: addr,
                lastErrorDescription: err
            )
        }

        let onlineCount = infos.filter(\.online).count
        await MainActor.run {
            isInitialized = true
            interfaces = infos
            if infos.isEmpty {
                networkStatus = "No interfaces"
            } else if onlineCount == infos.count {
                networkStatus = "All interfaces online"
            } else if onlineCount > 0 {
                networkStatus = "\(onlineCount)/\(infos.count) interfaces online"
            } else {
                networkStatus = "All interfaces offline"
            }
        }
    }

    /// Map a reticulum-swift `InterfaceType.rawValue` (the camelCase case name) to
    /// the display label the Model A path uses, so the UI reads identically either way.
    private static func displayType(forRaw raw: String?) -> String {
        switch raw {
        case "tcp": return "TCPClient"
        case "udp": return "UDP"
        case "i2p": return "I2P"
        case "autoInterface": return "AutoInterface"
        case "rnode": return "RNode"
        case "ble": return "BLE"
        case "multipeerConnectivity": return "Multipeer"
        default: return raw ?? "Interface"
        }
    }
}
