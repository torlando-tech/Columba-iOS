//
//  BleConstants.swift
//  SwiftBLEBridge
//
//  Wire-format constants. Must match Columba Android's BleConstants.kt and
//  upstream ble-reticulum's BLEGATTServer.py verbatim — this is the protocol.
//

import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

public enum BleConstants {
    // MARK: - GATT UUIDs (wire-compat across iOS / Android / Linux)

    /// Primary service container; advertised. Matches Android's
    /// `BleConstants.SERVICE_UUID` and upstream
    /// `BLEGATTServer.SERVICE_UUID`.
    public static let serviceUuid = "37145b00-442d-4a94-917f-8f42c5da28e3"

    /// RX characteristic — centrals write fragments here (and the initial
    /// 16-byte identity handshake). WRITE + WRITE_WITHOUT_RESPONSE.
    public static let rxCharUuid = "37145b00-442d-4a94-917f-8f42c5da28e5"

    /// TX characteristic — peripherals notify fragments here. READ + NOTIFY.
    /// Centrals subscribe by writing CCCD.
    public static let txCharUuid = "37145b00-442d-4a94-917f-8f42c5da28e4"

    /// Identity characteristic — 16-byte RNS Transport identity hash. READ.
    public static let identityCharUuid = "37145b00-442d-4a94-917f-8f42c5da28e6"

    /// Client Characteristic Configuration Descriptor — standard BLE.
    public static let cccdDescriptorUuid = "00002902-0000-1000-8000-00805f9b34fb"

    // MARK: - Protocol constants

    /// 16-byte identity hash size (matches `RNS.Transport.IDENTITY_HASH_LENGTH`).
    public static let identitySize = 16

    /// Fragment header byte count: `[Type:1][Sequence:2 BE][Total:2 BE]`.
    public static let fragmentHeaderSize = 5

    /// MTU fallback when iOS reports < this. BLE 4.0 floor minus ATT overhead.
    public static let minimumUsableMtu = 23

    // MARK: - Convenience CoreBluetooth wrappers

    #if canImport(CoreBluetooth)
    public static let serviceCBUUID = CBUUID(string: serviceUuid)
    public static let rxCharCBUUID = CBUUID(string: rxCharUuid)
    public static let txCharCBUUID = CBUUID(string: txCharUuid)
    public static let identityCharCBUUID = CBUUID(string: identityCharUuid)
    public static let cccdDescriptorCBUUID = CBUUID(string: cccdDescriptorUuid)
    #endif
}
