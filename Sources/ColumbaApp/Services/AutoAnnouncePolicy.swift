//
//  AutoAnnouncePolicy.swift
//  ColumbaApp
//
//  Pure value type that captures the user's auto-announce settings at a
//  point in time and decides whether each of the three trigger kinds
//  should fire. Extracted from inline `UserDefaults.standard.bool(...)`
//  reads so the gating logic is unit-testable without bringing up the
//  full AppServices stack.
//

import Foundation

/// Decides whether each auto-announce trigger should fire, based on the
/// current state of the user's settings.
///
/// The four UserDefaults keys this snapshots:
///
///  - `auto_announce_enabled` — master kill switch. False suppresses
///    every trigger regardless of the granular flags below.
///  - `auto_announce_on_interval` — periodic timer trigger.
///  - `auto_announce_on_tcp_reconnect` — fires on TCP/RNode interface
///    transitions to `.connected` (and on the polled state-observer's
///    isConnected→true edge).
///  - `auto_announce_on_peer_spawned` — fires when AutoInterface / BLE
///    / MPC accepts a new peer.
///
/// Defaults are registered as `true` for all four keys (see
/// `SettingsViewModel.loadLocalSettings`) so a fresh install behaves the
/// way pre-granular-trigger Columba did when the master was on.
public struct AutoAnnouncePolicy: Equatable, Sendable {
    public let masterEnabled: Bool
    public let onInterval: Bool
    public let onTcpReconnect: Bool
    public let onPeerSpawned: Bool

    public init(
        masterEnabled: Bool,
        onInterval: Bool,
        onTcpReconnect: Bool,
        onPeerSpawned: Bool
    ) {
        self.masterEnabled = masterEnabled
        self.onInterval = onInterval
        self.onTcpReconnect = onTcpReconnect
        self.onPeerSpawned = onPeerSpawned
    }

    /// Snapshot the current state of `defaults`.
    public static func current(defaults: UserDefaults = .standard) -> AutoAnnouncePolicy {
        AutoAnnouncePolicy(
            masterEnabled: defaults.bool(forKey: "auto_announce_enabled"),
            onInterval: defaults.bool(forKey: "auto_announce_on_interval"),
            onTcpReconnect: defaults.bool(forKey: "auto_announce_on_tcp_reconnect"),
            onPeerSpawned: defaults.bool(forKey: "auto_announce_on_peer_spawned")
        )
    }

    /// True iff the periodic interval-based announce trigger should fire.
    public var shouldFireOnInterval: Bool {
        masterEnabled && onInterval
    }

    /// True iff the on-(re)connect announce trigger should fire.
    public var shouldFireOnTcpReconnect: Bool {
        masterEnabled && onTcpReconnect
    }

    /// True iff the on-peer-spawn announce trigger should fire.
    public var shouldFireOnPeerSpawned: Bool {
        masterEnabled && onPeerSpawned
    }
}
