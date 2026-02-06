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

    /// 64-byte public key (encryption || signing) as hex string.
    public let publicKeyHex: String

    /// Whether using auto-generated identicon or custom icon.
    public var usesIdenticon: Bool

    /// Custom icon image data if set.
    public var customIconData: Data?

    /// Default display name when none set.
    public static let defaultDisplayName = "Unknown Peer"

    /// QR code string in Android Columba-compatible format.
    /// Format: `lxma://<destination_hash_hex>:<public_key_hex>`
    public var qrCodeString: String {
        guard !identityHash.isEmpty, !publicKeyHex.isEmpty else {
            return identityHash
        }
        return "lxma://\(identityHash):\(publicKeyHex)"
    }

    public init(
        displayName: String = "",
        identityHash: String = "",
        publicKeyHex: String = "",
        usesIdenticon: Bool = true,
        customIconData: Data? = nil
    ) {
        self.displayName = displayName
        self.identityHash = identityHash
        self.publicKeyHex = publicKeyHex
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
    public var isDeliveryRetrievalExpanded: Bool = false

    // MARK: - Network Settings

    public var isConnected: Bool = false
    public var connectedInterface: String = "TCP (127.0.0.1:4242)"
    public var isReconnecting: Bool = false
    public var reconnectError: String?

    // MARK: - Identity Settings

    /// Current identity information.
    public var identity = IdentityInfo()

    /// Current icon appearance (nil = identicon).
    public var iconAppearance: IconAppearance?

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

    // MARK: - Delivery & Retrieval Settings

    /// Default delivery method: "direct" or "propagated"
    public var defaultDeliveryMethod: String = "direct"

    /// Whether to retry via relay when direct delivery fails.
    public var retryViaRelay: Bool = false

    /// Whether auto-select relay is enabled.
    public var autoSelectRelay: Bool = true

    /// Selected relay node display name (read from PropagationNodeManager).
    public var selectedRelayName: String?

    /// Whether auto-retrieve from relay is enabled.
    public var autoRetrieveEnabled: Bool = false

    /// Auto-retrieve interval in seconds.
    public var autoRetrieveInterval: TimeInterval = 3600

    /// Whether a sync is currently in progress.
    public var isSyncing: Bool = false

    /// Current sync progress (0.0 to 1.0).
    public var syncProgress: Double = 0.0

    /// Last sync time for display.
    public var lastSyncTime: Date?

    /// Sync error message.
    public var syncError: String?

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
        // Load TCP server address from InterfaceRepository (single source of truth)
        let interfaceRepo = InterfaceRepository()
        if let tcpEntity = interfaceRepo.getEnabledInterfaces().first(where: { $0.type == .tcpClient }),
           case .tcpClient(let config) = tcpEntity.config {
            connectedInterface = "TCP (\(config.targetHost):\(config.targetPort))"
        } else {
            connectedInterface = "No TCP interface"
        }

        // Load display name from repository
        identity.displayName = await settingsRepository.getDisplayName()
        savedDisplayName = identity.displayName

        // Load identity hash and public key from AppServices
        let pubKeyHex = appServices.identity?.publicKeys
            .map { String(format: "%02x", $0) }.joined() ?? ""
        identity = IdentityInfo(
            displayName: identity.displayName,
            identityHash: appServices.localIdentityHashHex,
            publicKeyHex: pubKeyHex,
            usesIdenticon: true
        )

        // Load icon appearance
        iconAppearance = await settingsRepository.getIconAppearance()

        // Update connection state from AppServices
        isConnected = appServices.isConnected

        // Load delivery/retrieval settings
        defaultDeliveryMethod = await settingsRepository.getDefaultDeliveryMethod()
        retryViaRelay = await settingsRepository.getRetryViaRelay()
        autoSelectRelay = await settingsRepository.getAutoSelectRelay()
        autoRetrieveEnabled = await settingsRepository.getPeriodicSyncEnabled()
        autoRetrieveInterval = await settingsRepository.getSyncInterval()

        // Load propagation manager state
        if let propManager = appServices.propagationManager {
            selectedRelayName = propManager.selectedNodeName
            lastSyncTime = propManager.lastSyncTime
        }
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

    /// Update icon appearance and persist.
    @MainActor
    public func updateIconAppearance(_ icon: IconAppearance?) async {
        iconAppearance = icon
        await settingsRepository.setIconAppearance(icon)
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

    /// Save delivery/retrieval settings.
    @MainActor
    public func saveDeliverySettings() async {
        await settingsRepository.setDefaultDeliveryMethod(defaultDeliveryMethod)
        await settingsRepository.setRetryViaRelay(retryViaRelay)
        await settingsRepository.setAutoSelectRelay(autoSelectRelay)
        await settingsRepository.setPeriodicSyncEnabled(autoRetrieveEnabled)
        await settingsRepository.setSyncInterval(autoRetrieveInterval)

        // Update propagation manager
        if let propManager = appServices.propagationManager {
            propManager.autoSelectEnabled = autoSelectRelay
            propManager.periodicSyncEnabled = autoRetrieveEnabled
            propManager.syncInterval = autoRetrieveInterval
            if autoRetrieveEnabled {
                propManager.startPeriodicSync()
            } else {
                propManager.stopPeriodicSync()
            }
        }
    }

    /// Trigger immediate sync from propagation node.
    @MainActor
    public func syncNow() async {
        guard let propManager = appServices.propagationManager else {
            syncError = "Propagation manager not available"
            return
        }

        isSyncing = true
        syncError = nil

        await propManager.syncNow()

        syncProgress = propManager.syncState.progress
        lastSyncTime = propManager.lastSyncTime
        isSyncing = false

        if let error = propManager.syncState.errorDescription {
            syncError = error
        }
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
