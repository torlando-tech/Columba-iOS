//
//  BleGattClient.swift
//  SwiftBLEBridge
//
//  Per-peer GATT client state. Tracks the discovery → handshake → data
//  state machine for centrals (i.e. peripherals we connect to).
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

/// State of a single GATT client (one CBPeripheral we connect to).
internal final class BleGattClient {

    /// State of the connection handshake. iOS-side mirror of Android's
    /// `BleGattClient` state ladder.
    enum HandshakeState {
        case connecting          // CBCentralManager.connect issued
        case discoveringServices // didConnect → discoverServices called
        case discoveringChars    // didDiscoverServices → discoverCharacteristics called
        case readingIdentity     // setNotifyValue(true) on TX done; reading Identity char
        case writingIdentity     // Identity received; writing our own to RX
        case established         // handshake complete; data plane open
        case failed              // any step errored
    }

    let peripheral: CBPeripheral

    var state: HandshakeState = .connecting
    var mtu: Int = BleConstants.minimumUsableMtu
    var rxChar: CBCharacteristic?
    var txChar: CBCharacteristic?
    var identityChar: CBCharacteristic?

    /// Peer's identity (16 bytes) once we've read it from the Identity char.
    var peerIdentity: Data?

    /// Whether we've already fired `on_device_connected` for this peer.
    /// Prevents duplicate fires when MTU arrives before handshake completes.
    var connectedFired: Bool = false

    /// Whether we've already fired `on_mtu_negotiated`. Same dedup reason.
    var mtuFired: Bool = false

    /// When the GATT connection was established (didConnect → service
    /// discovery complete). Used to compute connection duration for the
    /// BLE Connections UI screen.
    var connectedAt: Date = Date()

    /// Most-recent RSSI sample from `readRSSI()`. nil until first read
    /// completes. The bridge polls periodically post-connect.
    var rssi: Int?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
}

#endif
