//
//  BlePowerSettings.swift
//  SwiftBLEBridge
//
//  Power preset surface. iOS auto-manages scan/advertise duty cycle, so this
//  is informational on our end; the Python driver still calls `set_power_mode`
//  for Android-parity, we record it and report back.
//

import Foundation

public enum BlePowerPreset: String, Sendable, CaseIterable {
    case aggressive
    case balanced
    case saver
}

public struct BlePowerSettings: Sendable, Equatable {
    public let preset: BlePowerPreset
    public let discoveryIntervalMs: Int
    public let discoveryIntervalIdleMs: Int
    public let scanDurationMs: Int
    public let advertisingRefreshIntervalMs: Int

    public init(
        preset: BlePowerPreset = .balanced,
        discoveryIntervalMs: Int = 10_000,
        discoveryIntervalIdleMs: Int = 30_000,
        scanDurationMs: Int = 5_000,
        advertisingRefreshIntervalMs: Int = 60_000
    ) {
        self.preset = preset
        self.discoveryIntervalMs = discoveryIntervalMs
        self.discoveryIntervalIdleMs = discoveryIntervalIdleMs
        self.scanDurationMs = scanDurationMs
        self.advertisingRefreshIntervalMs = advertisingRefreshIntervalMs
    }
}
