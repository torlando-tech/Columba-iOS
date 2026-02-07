//
//  NetworkStatusViewModel.swift
//  ColumbaApp
//
//  ViewModel for the Network Status screen.
//  Polls transport for all registered interfaces and exposes them as observable state.
//

import Foundation
import SwiftUI
import ReticulumSwift

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
/// Polls ReticuLumTransport every second to get a snapshot of all registered
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
}
