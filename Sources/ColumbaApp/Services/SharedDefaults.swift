//
//  SharedDefaults.swift
//  ColumbaApp
//
//  App Group UserDefaults accessor shared between main app and Network Extension.
//

import Foundation

/// Shared UserDefaults backed by the App Group container.
///
/// Used for settings that the Network Extension needs to read
/// (e.g., transport_enabled, interface configurations).
public enum SharedDefaults {
    /// App Group UserDefaults suite. Falls back to standard if group unavailable.
    public static let suite: UserDefaults = {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }()
}
