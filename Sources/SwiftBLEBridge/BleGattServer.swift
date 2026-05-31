//
//  BleGattServer.swift
//  SwiftBLEBridge
//
//  Per-subscriber peripheral-mode state. Each central that subscribes to
//  our TX characteristic gets a `BleGattServerPeer` so we can track its
//  identity, MTU, and outbound queue.
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

internal final class BleGattServerPeer {

    enum HandshakeState {
        case awaitingIdentity   // subscribed but hasn't sent its 16-byte identity yet
        case established        // identity received; data plane open
    }

    let central: CBCentral
    var state: HandshakeState = .awaitingIdentity
    var identity: Data?
    var mtu: Int

    /// Outbound queue when CBPeripheralManager.updateValue returns false
    /// (backpressure). Drained on peripheralManagerIsReady(toUpdateSubscribers:).
    var pendingNotifies: [Data] = []

    /// When this central first subscribed to our TX char (or sent its
    /// identity handshake). Used to compute connection duration for the
    /// BLE Connections UI screen.
    var connectedAt: Date = Date()

    init(central: CBCentral) {
        self.central = central
        self.mtu = central.maximumUpdateValueLength
    }
}

#endif
