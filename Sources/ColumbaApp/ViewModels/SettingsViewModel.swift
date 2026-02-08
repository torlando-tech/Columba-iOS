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

    /// Block messages from senders not in contacts list.
    public var blockUnknownSenders: Bool = false

    // MARK: - Notification Settings

    public var isNotificationsEnabled: Bool = true
    public var showMessagePreviews: Bool = true
    public var playSounds: Bool = true
    public var vibrate: Bool = true

    // MARK: - Auto Announce Settings

    public var isAutoAnnounceEnabled: Bool = true
    public var announceIntervalHours: Int = 3
    public var lastAnnounceTime: Date?
    public var isManualAnnouncing: Bool = false
    public var manualAnnounceSuccess: Bool = false
    public var manualAnnounceError: String?

    // MARK: - Location Sharing Settings

    public var isLocationSharingEnabled: Bool = false
    public var sharePreciseLocation: Bool = false
    public var locationUpdateInterval: Int = 60

    // MARK: - Delivery & Retrieval Settings

    /// Default delivery method for large messages: "direct" or "propagated"
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

    // MARK: - Active Identity Info

    /// Display name of the currently active identity (from IdentityManager).
    public var activeIdentityName: String = ""

    // MARK: - Dependencies

    private let appServices: AppServices
    private let settingsRepository: SettingsRepository
    private let identityManager: IdentityManager?

    // MARK: - Initialization

    init(appServices: AppServices, settingsRepository: SettingsRepository, identityManager: IdentityManager? = nil) {
        self.appServices = appServices
        self.settingsRepository = settingsRepository
        self.identityManager = identityManager
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
            connectedInterface = "TCP (\(config.targetHost):\(String(config.targetPort)))"
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

        // Load active identity name from IdentityManager
        if let mgr = identityManager {
            if let active = await mgr.getActiveIdentity() {
                activeIdentityName = active.displayName
            }
        }

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

        blockUnknownSenders = defaults.bool(forKey: "block_unknown_senders")
        isNotificationsEnabled = defaults.bool(forKey: "notifications_enabled")
        showMessagePreviews = defaults.bool(forKey: "show_message_previews")
        playSounds = defaults.bool(forKey: "play_sounds")
        vibrate = defaults.bool(forKey: "vibrate")
        isAutoAnnounceEnabled = defaults.bool(forKey: "auto_announce_enabled")
        let storedInterval = defaults.integer(forKey: "announce_interval_hours")
        announceIntervalHours = storedInterval > 0 ? storedInterval : 3
        let lastTs = defaults.double(forKey: "last_announce_time")
        lastAnnounceTime = lastTs > 0 ? Date(timeIntervalSince1970: lastTs) : nil
        isLocationSharingEnabled = defaults.bool(forKey: "location_sharing_enabled")
        sharePreciseLocation = defaults.bool(forKey: "share_precise_location")
        locationUpdateInterval = defaults.integer(forKey: "location_update_interval")

        if let mapSource = defaults.string(forKey: "map_source"),
           let source = MapSource(rawValue: mapSource) {
            selectedMapSource = source
        }

        // Set defaults for first launch and persist them
        if !defaults.bool(forKey: "settings_initialized") {
            isNotificationsEnabled = true
            showMessagePreviews = true
            playSounds = true
            vibrate = true
            isAutoAnnounceEnabled = true
            announceIntervalHours = 3
            locationUpdateInterval = 60
            defaults.set(true, forKey: "settings_initialized")
            // Persist notification defaults so NotificationService can read them
            saveSettings()
        }
    }

    /// Save settings to UserDefaults.
    public func saveSettings() {
        let defaults = UserDefaults.standard

        defaults.set(blockUnknownSenders, forKey: "block_unknown_senders")
        defaults.set(isNotificationsEnabled, forKey: "notifications_enabled")
        defaults.set(showMessagePreviews, forKey: "show_message_previews")
        defaults.set(playSounds, forKey: "play_sounds")
        defaults.set(vibrate, forKey: "vibrate")
        defaults.set(isAutoAnnounceEnabled, forKey: "auto_announce_enabled")
        defaults.set(announceIntervalHours, forKey: "announce_interval_hours")
        defaults.set(isLocationSharingEnabled, forKey: "location_sharing_enabled")
        defaults.set(sharePreciseLocation, forKey: "share_precise_location")
        defaults.set(locationUpdateInterval, forKey: "location_update_interval")
        defaults.set(selectedMapSource.rawValue, forKey: "map_source")
    }

    /// Sync auto-announce manager state with current settings.
    ///
    /// Call after changing the auto-announce toggle or interval.
    @MainActor
    public func syncAutoAnnounce() {
        if let manager = appServices.autoAnnounceManager {
            if isAutoAnnounceEnabled {
                manager.start()
            } else {
                manager.stop()
            }
        }
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

    /// Send announce to the network (from Identity page).
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
            recordAnnounceTime()
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

    /// Trigger a manual announce from the Auto Announce card.
    @MainActor
    public func triggerManualAnnounce() async {
        isManualAnnouncing = true
        manualAnnounceSuccess = false
        manualAnnounceError = nil

        do {
            try await appServices.sendAnnounce(displayName: identity.displayName)
            manualAnnounceSuccess = true
            recordAnnounceTime()
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    self.manualAnnounceSuccess = false
                }
            }
        } catch {
            manualAnnounceError = error.localizedDescription
            Task {
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run {
                    self.manualAnnounceError = nil
                }
            }
        }

        isManualAnnouncing = false
    }

    /// Record last announce timestamp.
    private func recordAnnounceTime() {
        lastAnnounceTime = Date()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_announce_time")
    }

    /// Next scheduled announce time (based on last + interval).
    public var nextAnnounceTime: Date? {
        guard isAutoAnnounceEnabled, let last = lastAnnounceTime else { return nil }
        return last.addingTimeInterval(Double(announceIntervalHours) * 3600)
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
