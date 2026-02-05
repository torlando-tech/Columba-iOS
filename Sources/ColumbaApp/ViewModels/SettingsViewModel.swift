//
//  SettingsViewModel.swift
//  ColumbaApp
//
//  ViewModel for settings screen using @Observable macro.
//  Manages all toggle states and identity information.
//

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Identity Model

/// Represents the user's identity information.
public struct IdentityInfo: Equatable {
    /// Custom display name set by user.
    public var displayName: String

    /// Identity hash as hex string.
    public let identityHash: String

    /// Whether using auto-generated identicon or custom icon.
    public var usesIdenticon: Bool

    /// Custom icon image data if set.
    public var customIconData: Data?

    /// Default display name when none set.
    public static let defaultDisplayName = "Unknown Peer"

    public init(
        displayName: String = "",
        identityHash: String = "",
        usesIdenticon: Bool = true,
        customIconData: Data? = nil
    ) {
        self.displayName = displayName
        self.identityHash = identityHash
        self.usesIdenticon = usesIdenticon
        self.customIconData = customIconData
    }
}

// MARK: - SettingsViewModel

/// ViewModel for settings screen.
///
/// Uses iOS 17+ @Observable macro for automatic SwiftUI observation.
/// Manages all toggle states and identity configuration.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class SettingsViewModel {
    // MARK: - Types

    /// Available map sources.
    public enum MapSource: String, CaseIterable, Identifiable {
        case apple = "Apple Maps"
        case openStreetMap = "OpenStreetMap"
        case satellite = "Satellite"

        public var id: String { rawValue }
    }

    // MARK: - Card Expansion State

    public var isNetworkExpanded: Bool = false
    public var isIdentityExpanded: Bool = false
    public var isPrivacyExpanded: Bool = false
    public var isNotificationsExpanded: Bool = false
    public var isAutoAnnounceExpanded: Bool = false
    public var isLocationSharingExpanded: Bool = false
    public var isMapSourcesExpanded: Bool = false

    // MARK: - Network Settings

    public var isConnected: Bool = false
    public var connectedInterface: String = "TCP (127.0.0.1:4242)"

    // MARK: - Identity Settings

    /// Current identity information.
    public var identity = IdentityInfo(
        displayName: "emu",
        identityHash: "f3b4bba6765b2ae4414a32b6408a6806",
        usesIdenticon: true
    )

    /// Saved display name for change detection.
    private var savedDisplayName: String = "emu"

    /// Whether identity has unsaved changes.
    public var hasUnsavedChanges: Bool {
        identity.displayName != savedDisplayName
    }

    // MARK: - Privacy Settings

    public var isPrivacyEnabled: Bool = false

    // MARK: - Notification Settings

    public var isNotificationsEnabled: Bool = true
    public var showMessagePreviews: Bool = true
    public var playSounds: Bool = true
    public var vibrate: Bool = true

    // MARK: - Auto Announce Settings

    public var isAutoAnnounceEnabled: Bool = true
    public var announceOnLaunch: Bool = true
    public var announceIntervalMinutes: Int = 15

    // MARK: - Location Sharing Settings

    public var isLocationSharingEnabled: Bool = false
    public var sharePreciseLocation: Bool = false
    public var locationUpdateInterval: Int = 60

    // MARK: - Map Settings

    public var selectedMapSource: MapSource = .apple

    // MARK: - Initialization

    public init() {
        loadSettings()
    }

    // MARK: - Methods

    /// Load settings from UserDefaults.
    private func loadSettings() {
        let defaults = UserDefaults.standard

        isPrivacyEnabled = defaults.bool(forKey: "privacy_enabled")
        isNotificationsEnabled = defaults.bool(forKey: "notifications_enabled")
        showMessagePreviews = defaults.bool(forKey: "show_message_previews")
        playSounds = defaults.bool(forKey: "play_sounds")
        vibrate = defaults.bool(forKey: "vibrate")
        isAutoAnnounceEnabled = defaults.bool(forKey: "auto_announce_enabled")
        announceOnLaunch = defaults.bool(forKey: "announce_on_launch")
        announceIntervalMinutes = defaults.integer(forKey: "announce_interval")
        isLocationSharingEnabled = defaults.bool(forKey: "location_sharing_enabled")
        sharePreciseLocation = defaults.bool(forKey: "share_precise_location")
        locationUpdateInterval = defaults.integer(forKey: "location_update_interval")

        if let mapSource = defaults.string(forKey: "map_source"),
           let source = MapSource(rawValue: mapSource) {
            selectedMapSource = source
        }

        // Set defaults for first launch
        if !defaults.bool(forKey: "settings_initialized") {
            isNotificationsEnabled = true
            showMessagePreviews = true
            playSounds = true
            vibrate = true
            isAutoAnnounceEnabled = true
            announceOnLaunch = true
            announceIntervalMinutes = 15
            locationUpdateInterval = 60
            defaults.set(true, forKey: "settings_initialized")
        }
    }

    /// Save settings to UserDefaults.
    public func saveSettings() {
        let defaults = UserDefaults.standard

        defaults.set(isPrivacyEnabled, forKey: "privacy_enabled")
        defaults.set(isNotificationsEnabled, forKey: "notifications_enabled")
        defaults.set(showMessagePreviews, forKey: "show_message_previews")
        defaults.set(playSounds, forKey: "play_sounds")
        defaults.set(vibrate, forKey: "vibrate")
        defaults.set(isAutoAnnounceEnabled, forKey: "auto_announce_enabled")
        defaults.set(announceOnLaunch, forKey: "announce_on_launch")
        defaults.set(announceIntervalMinutes, forKey: "announce_interval")
        defaults.set(isLocationSharingEnabled, forKey: "location_sharing_enabled")
        defaults.set(sharePreciseLocation, forKey: "share_precise_location")
        defaults.set(locationUpdateInterval, forKey: "location_update_interval")
        defaults.set(selectedMapSource.rawValue, forKey: "map_source")
    }

    /// Save the current display name.
    public func saveDisplayName() {
        savedDisplayName = identity.displayName
        saveSettings()
    }

    /// Copy identity hash to clipboard.
    public func copyIdentityHash() {
        #if canImport(UIKit)
        UIPasteboard.general.string = identity.identityHash
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identity.identityHash, forType: .string)
        #endif
    }
}
