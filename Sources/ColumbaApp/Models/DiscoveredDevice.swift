//
//  DiscoveredDevice.swift
//  ColumbaApp
//
//  A discovered BLE peripheral with metadata used by the RNode wizard's
//  device-discovery step.
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
