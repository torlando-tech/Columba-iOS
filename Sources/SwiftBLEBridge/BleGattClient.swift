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
        case readingIdentity     // reading the peer's Identity characteristic
        case subscribing         // enabling TX notifications; awaiting confirmation
        case writingIdentity     // notifications ready; writing our identity with response
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

    /// CoreBluetooth confirms subscription asynchronously. The data plane must
    /// not be declared established until this is true and the identity write
    /// has received its ATT response, matching Android's handshake ladder.
    var notificationsReady: Bool = false

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

    /// Outbound fragments awaiting CoreBluetooth transmit-queue space.
    /// writeValue(.withoutResponse) silently drops once the per-peripheral
    /// queue is full (iOS 11+), so frames are queued here and drained as space
    /// frees up (see drainClientWritesLocked / peripheralIsReady). Discarded
    /// with the client on disconnect.
    var pendingWrites: [Data] = []

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
}

#endif
