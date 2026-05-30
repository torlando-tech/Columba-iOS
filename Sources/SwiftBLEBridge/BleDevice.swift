//
//  BleDevice.swift
//  SwiftBLEBridge
//
//  Plain value type passed up to Python on `on_device_discovered`. Mirrors
//  upstream `BLEDevice` dataclass in bluetooth_driver.py.
//

import Foundation

public struct BleDevice: Sendable, Equatable {
    /// Stable per-peripheral key. On iOS this is `CBPeripheral.identifier.uuidString`.
    /// Note: for Android / Linux peers this rotates every ~15 min when their MAC
    /// rotates — the driver tracks address↔identity reunification to surface
    /// `on_address_changed` to the upstream interface.
    public let address: String

    /// Friendly name from the advertisement, if present.
    public let name: String

    /// Last RSSI sample, in dBm.
    public let rssi: Int

    /// Service UUIDs the peer advertised. Used by the driver to filter
    /// non-Columba devices before reporting.
    public let serviceUuids: [String]

    public init(address: String, name: String, rssi: Int, serviceUuids: [String]) {
        self.address = address
        self.name = name
        self.rssi = rssi
        self.serviceUuids = serviceUuids
    }
}
