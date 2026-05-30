//
//  BleConnectionState.swift
//  SwiftBLEBridge
//
//  Per-peer connection state surfaced to the Python driver + the iOS Settings
//  UI. Mirror of Android's BleConnectionDetails.
//

import Foundation

public enum BleConnectionRole: String, Sendable, Equatable {
    case central
    case peripheral
}

public struct BleConnectionDetails: Sendable, Equatable {
    public let address: String
    public let identityHashHex: String?
    public let role: BleConnectionRole
    public let mtu: Int
    public let rssi: Int?
    public let lastActivity: Date
    public let connectedAt: Date

    public init(
        address: String,
        identityHashHex: String?,
        role: BleConnectionRole,
        mtu: Int,
        rssi: Int?,
        lastActivity: Date,
        connectedAt: Date = Date()
    ) {
        self.address = address
        self.identityHashHex = identityHashHex
        self.role = role
        self.mtu = mtu
        self.rssi = rssi
        self.lastActivity = lastActivity
        self.connectedAt = connectedAt
    }
}
