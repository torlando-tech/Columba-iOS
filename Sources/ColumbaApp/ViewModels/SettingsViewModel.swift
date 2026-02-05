//
//  SettingsViewModel.swift
//  ColumbaApp
//
//  ViewModel for settings screen using @Observable macro.
//  Manages all toggle states and identity information.
//

import Foundation
import Observation
import LXMFSwift
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
    public var isReconnecting: Bool = false
    public var reconnectError: String?

    // MARK: - Identity Settings

    /// Current identity information.
    public var identity = IdentityInfo()

    /// Saved display name for change detection.
    private var savedDisplayName: String = ""

    /// Whether identity has unsaved changes.
    public var hasUnsavedChanges: Bool {
        identity.displayName != savedDisplayName
    }

    /// True while sending an announce.
    public var isAnnouncing: Bool = false

    /// Error message if announce fails.
    public var announceError: String?

    /// Success message after announce sent.
    public var announceSuccess: Bool = false

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

    // MARK: - Dependencies

    private let appServices: AppServices
    private let settingsRepository: SettingsRepository

    // MARK: - Initialization

    public init(appServices: AppServices, settingsRepository: SettingsRepository) {
        self.appServices = appServices
        self.settingsRepository = settingsRepository
        loadLocalSettings()
    }

    // MARK: - Methods

    /// Load settings from repository and AppServices.
    @MainActor
    public func loadSettings() async {
        // Load relay address from repository
        connectedInterface = "TCP (\(await settingsRepository.getRelayAddress()))"

        // Load display name from repository
        identity.displayName = await settingsRepository.getDisplayName()
        savedDisplayName = identity.displayName

        // Load identity hash from AppServices
        identity = IdentityInfo(
            displayName: identity.displayName,
            identityHash: appServices.localIdentityHashHex,
            usesIdenticon: true
        )

        // Update connection state from AppServices
        isConnected = appServices.isConnected
    }

    /// Load local settings from UserDefaults.
    private func loadLocalSettings() {
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
    @MainActor
    public func saveDisplayName() async {
        savedDisplayName = identity.displayName
        await settingsRepository.setDisplayName(identity.displayName)
        saveSettings()
    }

    /// Send announce to the network.
    @MainActor
    public func sendAnnounce() async {
        // Save display name first
        await settingsRepository.setDisplayName(identity.displayName)
        savedDisplayName = identity.displayName

        isAnnouncing = true
        announceError = nil
        announceSuccess = false

        do {
            try await appServices.sendAnnounce(displayName: identity.displayName)
            announceSuccess = true
            // Clear success after a delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    self.announceSuccess = false
                }
            }
        } catch {
            announceError = "Failed to announce: \(error.localizedDescription)"
        }

        isAnnouncing = false
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

    /// Reconnect to relay server.
    @MainActor
    public func reconnect(relayAddress: String) async {
        isReconnecting = true
        reconnectError = nil

        do {
            await settingsRepository.setRelayAddress(relayAddress)
            try await appServices.reconnect(relayAddress: relayAddress)
            connectedInterface = "TCP (\(relayAddress))"
        } catch {
            reconnectError = "Failed to connect: \(error.localizedDescription)"
        }

        isReconnecting = false
    }
}
