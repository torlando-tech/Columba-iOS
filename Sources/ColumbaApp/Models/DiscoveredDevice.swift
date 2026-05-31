//
//  DiscoveredDevice.swift
//  ColumbaApp
//
//  A discovered BLE peripheral with metadata. Shared by the RNode wizard's
//  device-discovery step (COLUMBA_RNODE_ENABLED) and the BLE device picker
//  (COLUMBA_BLE_ENABLED). Lives here (ungated) so neither feature flag owns
//  the type — extracted from BLEDevicePickerSheet.swift, which used to define
//  it under COLUMBA_BLE_ENABLED only.
//

import Foundation

/// A discovered BLE peripheral with metadata.
struct DiscoveredDevice: Identifiable {
    /// Unique identifier for SwiftUI list deduplication.
    let id = UUID()

    /// Peripheral identifier (used for deduplication).
    let peripheralId: UUID

    /// Peripheral name.
    let name: String

    /// Received signal strength indicator (dBm).
    var rssi: Int

    /// Last discovery timestamp.
    var lastSeen: Date
}
