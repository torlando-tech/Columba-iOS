//
//  SettingsViewModel.swift
//  ColumbaApp
//
//  ViewModel for settings screen using @Observable macro.
//  Manages all toggle states and identity information.
//

import Foundation
import RNSAPI
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

    /// 64-byte public key (encryption || signing) as hex string.
    public let publicKeyHex: String

    /// LXMF delivery destination hash as hex string.
    public var destinationHash: String

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
        destinationHash: String = "",
        usesIdenticon: Bool = true,
        customIconData: Data? = nil
    ) {
        self.displayName = displayName
        self.identityHash = identityHash
        self.publicKeyHex = publicKeyHex
        self.destinationHash = destinationHash
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

    /// Image quality presets matching Android Columba.
    public enum ImageQualityPreset: String, CaseIterable, Identifiable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
        case original = "Original"

        public var id: String { rawValue }

        public var maxDimension: CGFloat {
            switch self {
            case .low: return 320
            case .medium: return 800
            case .high: return 2048
            case .original: return 8192
            }
        }

        public var targetSizeBytes: Int {
            switch self {
            case .low: return 32_768
            case .medium: return 131_072
            case .high: return 524_288
            case .original: return 26_214_400
            }
        }

        public var initialQuality: CGFloat {
            switch self {
            case .low: return 0.60
            case .medium: return 0.75
            case .high: return 0.90
            case .original: return 0.95
            }
        }

        public var minQuality: CGFloat {
            switch self {
            case .low: return 0.30
            case .medium: return 0.40
            case .high: return 0.50
            case .original: return 0.90
            }
        }

        public var description: String {
            switch self {
            case .low: return "32KB max - optimized for LoRa and low-bandwidth links"
            case .medium: return "128KB max - balanced quality for mesh networks"
            case .high: return "512KB max - good quality for general use"
            case .original: return "25MB max - minimal compression, full quality"
            }
        }
    }

    // MARK: - Transport Mode

    public var isTransportEnabled: Bool = false
    public var isTransportExpanded: Bool = false

    // MARK: - Network Backend (RNS engine)

    /// Whether the native Swift backend is selected (vs embedded Python).
    /// Persisted via `BackendPreference`; applied on next app launch.
    public var useSwiftBackend: Bool = false
    public var isBackendExpanded: Bool = false
    /// True once the user changes the backend, surfacing the "relaunch to
    /// apply" hint until the app is restarted.
    public var backendChangePending: Bool = false

    // MARK: - Card Expansion State

    public var isNetworkExpanded: Bool = false
    public var isIdentityExpanded: Bool = false
    public var isPrivacyExpanded: Bool = false
    public var isNotificationsExpanded: Bool = false
    public var isAutoAnnounceExpanded: Bool = false
    public var isLocationSharingExpanded: Bool = false
    public var isDeliveryRetrievalExpanded: Bool = false
    public var isMapSourcesExpanded: Bool = false
    public var isAppearanceExpanded: Bool = false
    public var isImageQualityExpanded: Bool = false

    // MARK: - Network Settings

    public var isConnected: Bool = false
    public var connectedInterface: String = ""
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

    // Per-type notification toggles (matches Android)
    public var notifyReceivedMessage: Bool = true
    public var notifyReceivedMessageFavorite: Bool = false
    public var notifyHeardAnnounce: Bool = false
    public var notifyAnnounceDirectOnly: Bool = false
    public var notifyAnnounceExcludeTcp: Bool = false
    public var notifyBleConnected: Bool = false
    public var notifyBleDisconnected: Bool = false

    // MARK: - Auto Announce Settings

    public var isAutoAnnounceEnabled: Bool = true
    public var announceIntervalHours: Int = 3
    public var lastAnnounceTime: Date?
    public var isManualAnnouncing: Bool = false
    public var manualAnnounceSuccess: Bool = false
    public var manualAnnounceError: String?

    // Granular announce triggers (all gated under isAutoAnnounceEnabled).
    // Default true — equivalent to "all triggers active" pre-introduction.
    /// Fire an announce on the periodic interval timer.
    public var autoAnnounceOnInterval: Bool = true
    /// Fire an announce when a TCP / RNode / static interface (re)connects.
    public var autoAnnounceOnTcpReconnect: Bool = true
    /// Fire an announce when an AutoInterface / BLE / MPC peer is spawned.
    public var autoAnnounceOnPeerSpawned: Bool = true

    // MARK: - Location Sharing Settings

    /// Live reflection of whether location is being shared with any peer.
    /// Refreshed by the polling loop. Setting to false calls stopAllSharing().
    public var isLocationSharingEnabled: Bool = false
    /// Location precision radius in meters (0 = precise GPS, 100/1000/10000 = coarsened).
    public var locationPrecisionRadius: Int = 0
    /// Default duration for new location sharing sessions (raw value of SharingDuration).
    public var defaultSharingDuration: String = SharingDuration.oneHour.rawValue

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

    // MARK: - Image Quality Settings

    public var imageQualityPreset: ImageQualityPreset = .high

    // MARK: - Map Settings

    /// Whether HTTP map tile fetching is enabled (vs offline-only).
    public var mapHttpEnabled: Bool = true

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
        // Load display name from repository
        identity.displayName = await settingsRepository.getDisplayName()
        savedDisplayName = identity.displayName

        // Load identity hash, public key, and LXMF destination hash
        let pubKeyHex = appServices.identity?.publicKeys
            .map { String(format: "%02x", $0) }.joined() ?? ""
        // identity.hexHash = truncatedHash(pubkeys) — the true identity hash
        // localIdentityHashHex = Destination.hash(lxmf.delivery) — the LXMF destination hash
        let idHash = appServices.identity?.hexHash ?? ""
        let destHash = appServices.localIdentityHashHex
        identity = IdentityInfo(
            displayName: identity.displayName,
            identityHash: idHash,
            publicKeyHex: pubKeyHex,
            destinationHash: destHash,
            usesIdenticon: true
        )

        // Unify display name from LocalIdentity and SettingsRepository.
        // LocalIdentity.displayName is the canonical source; SettingsRepository
        // is a secondary copy that can get out of sync (e.g. app group migration).
        let repoName = identity.displayName
        if let mgr = identityManager, let active = await mgr.getActiveIdentity() {
            let idName = active.displayName
            let resolvedName: String
            if !idName.isEmpty && idName != "Anonymous Peer" {
                resolvedName = idName
            } else if !repoName.isEmpty {
                resolvedName = repoName
                // Repair LocalIdentity so it stays in sync.
                await mgr.renameIdentity(active.identityHash, newName: repoName)
            } else {
                resolvedName = idName
            }
            activeIdentityName = resolvedName
            // Keep both sources in sync
            if identity.displayName != resolvedName {
                identity.displayName = resolvedName
                savedDisplayName = resolvedName
                await settingsRepository.setDisplayName(resolvedName)
            }
        }

        // Load icon appearance
        iconAppearance = await settingsRepository.getIconAppearance()

        // Update connection state
        await refreshConnectionState()

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
    /// Register app-side `UserDefaults.standard` defaults at process launch.
    ///
    /// `NotificationService` (the foreground notification path) gates on
    /// `bool(forKey: "notifications_enabled")`, which returns `false` unless the
    /// key is registered. Registration used to live ONLY in `loadLocalSettings()`,
    /// which runs lazily the first time Settings is opened — so on a fresh install
    /// that never visits Settings, `notifications_enabled` stayed unregistered and
    /// the foreground notification path was silently suppressed. Call this from
    /// `App.init()` so the defaults exist before any reader runs. Registration is
    /// idempotent and process-wide. (ports #57 dc1024b)
    ///
    /// (Background notifications under Model B are posted by the Network Extension,
    /// which gates only on system authorization — not this default — so it is
    /// unaffected; this fixes the in-app/foreground path and is correct hygiene.)
    static func registerLocalDefaults() {
        UserDefaults.standard.register(defaults: [
            "notifications_enabled": true,
            "show_message_previews": true,
            "play_sounds": true,
            "vibrate": true,
            "auto_announce_enabled": true,
            "auto_announce_on_interval": true,
            "auto_announce_on_tcp_reconnect": true,
            "auto_announce_on_peer_spawned": true
        ])
    }

    private func loadLocalSettings() {
        let defaults = UserDefaults.standard

        // Defaults are registered at launch (App.init → registerLocalDefaults);
        // re-register here too since registration is idempotent and this VM may
        // be exercised in isolation (previews / tests).
        Self.registerLocalDefaults()

        blockUnknownSenders = defaults.bool(forKey: "block_unknown_senders")
        isNotificationsEnabled = defaults.bool(forKey: "notifications_enabled")
        showMessagePreviews = defaults.bool(forKey: "show_message_previews")
        playSounds = defaults.bool(forKey: "play_sounds")
        vibrate = defaults.bool(forKey: "vibrate")
        // Per-type notification defaults: received message defaults to true on first launch
        notifyReceivedMessage = defaults.object(forKey: "notify_received_message") as? Bool ?? true
        notifyReceivedMessageFavorite = defaults.bool(forKey: "notify_received_message_favorite")
        notifyHeardAnnounce = defaults.bool(forKey: "notify_heard_announce")
        notifyAnnounceDirectOnly = defaults.bool(forKey: "notify_announce_direct_only")
        notifyAnnounceExcludeTcp = defaults.bool(forKey: "notify_announce_exclude_tcp")
        notifyBleConnected = defaults.bool(forKey: "notify_ble_connected")
        notifyBleDisconnected = defaults.bool(forKey: "notify_ble_disconnected")
        isAutoAnnounceEnabled = defaults.bool(forKey: "auto_announce_enabled")
        autoAnnounceOnInterval = defaults.bool(forKey: "auto_announce_on_interval")
        autoAnnounceOnTcpReconnect = defaults.bool(forKey: "auto_announce_on_tcp_reconnect")
        autoAnnounceOnPeerSpawned = defaults.bool(forKey: "auto_announce_on_peer_spawned")
        let storedInterval = defaults.integer(forKey: "announce_interval_hours")
        announceIntervalHours = storedInterval > 0 ? storedInterval : 3
        let lastTs = defaults.double(forKey: "last_announce_time")
        lastAnnounceTime = lastTs > 0 ? Date(timeIntervalSince1970: lastTs) : nil
        isTransportEnabled = SharedDefaults.suite.bool(forKey: "transport_enabled")
        useSwiftBackend = BackendPreference.isSwift
        isLocationSharingEnabled = defaults.bool(forKey: "location_sharing_enabled")
        locationPrecisionRadius = defaults.integer(forKey: "location_precision_radius")
        if let storedDuration = defaults.string(forKey: "default_sharing_duration") {
            defaultSharingDuration = storedDuration
        }

        mapHttpEnabled = defaults.object(forKey: "map_http_enabled") as? Bool ?? true

        if let qualityRaw = defaults.string(forKey: "image_quality_preset"),
           let preset = ImageQualityPreset(rawValue: qualityRaw) {
            imageQualityPreset = preset
        }

        // Set defaults for first launch and persist them
        if !defaults.bool(forKey: "settings_initialized") {
            isNotificationsEnabled = true
            showMessagePreviews = true
            playSounds = true
            vibrate = true
            isAutoAnnounceEnabled = true
            autoAnnounceOnInterval = true
            autoAnnounceOnTcpReconnect = true
            autoAnnounceOnPeerSpawned = true
            announceIntervalHours = 3
            defaultSharingDuration = SharingDuration.oneHour.rawValue
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
        defaults.set(notifyReceivedMessage, forKey: "notify_received_message")
        defaults.set(notifyReceivedMessageFavorite, forKey: "notify_received_message_favorite")
        defaults.set(notifyHeardAnnounce, forKey: "notify_heard_announce")
        defaults.set(notifyAnnounceDirectOnly, forKey: "notify_announce_direct_only")
        defaults.set(notifyAnnounceExcludeTcp, forKey: "notify_announce_exclude_tcp")
        defaults.set(notifyBleConnected, forKey: "notify_ble_connected")
        defaults.set(notifyBleDisconnected, forKey: "notify_ble_disconnected")
        defaults.set(isAutoAnnounceEnabled, forKey: "auto_announce_enabled")
        defaults.set(autoAnnounceOnInterval, forKey: "auto_announce_on_interval")
        defaults.set(autoAnnounceOnTcpReconnect, forKey: "auto_announce_on_tcp_reconnect")
        defaults.set(autoAnnounceOnPeerSpawned, forKey: "auto_announce_on_peer_spawned")
        defaults.set(announceIntervalHours, forKey: "announce_interval_hours")
        SharedDefaults.suite.set(isTransportEnabled, forKey: "transport_enabled")
        defaults.set(isLocationSharingEnabled, forKey: "location_sharing_enabled")
        defaults.set(locationPrecisionRadius, forKey: "location_precision_radius")
        defaults.set(defaultSharingDuration, forKey: "default_sharing_duration")
        defaults.set(mapHttpEnabled, forKey: "map_http_enabled")
        defaults.set(imageQualityPreset.rawValue, forKey: "image_quality_preset")
    }

    /// Refresh connection state from AppServices.
    ///
    /// Reads isConnected and builds the active interface string.
    /// Called from loadSettings() and periodically by the view.
    @MainActor
    public func refreshConnectionState() async {
        // In Model B the NE owns the TCP relay and the app owns no local TCP
        // interface, so reading app interfaces would always report
        // "disconnected". Reflect the NE relay's state (via the proxy) for TCP;
        // app-owned radios (Auto / BLE / RNode) are read locally in both models.
        let modelB = BackendPreference.modelB

        // Build connected interface string from all active interfaces.
        var activeInterfaces: [String] = []

        if modelB {
            // Model B: the NE owns MULTIPLE relays (one `ne-tcp-relay-<entityId>` per
            // enabled tcpClient). Label the card with the relays that are ACTUALLY online,
            // matched by entity id via the per-relay snapshot — NOT the first-configured
            // one. The old code labeled with `.first(tcpClient)` whenever ANY relay was up
            // (a coarse any-online bool), so a down first relay (e.g. a dead community hub)
            // was shown as the connected interface while a different relay carried traffic.
            let onlineIds = Set(await appServices.neTcpRelayStatuses().filter { $0.online }.map { $0.entityId })
            let interfaceRepo = InterfaceRepository()
            for entity in interfaceRepo.getEnabledInterfaces() where entity.type == .tcpClient {
                guard onlineIds.contains(entity.id), case .tcpClient(let config) = entity.config else { continue }
                activeInterfaces.append("TCP (\(config.targetHost):\(String(config.targetPort)))")
            }
        } else if let tcp = appServices.tcpInterface, await tcp.state == .connected {
            // Model A: the app owns a single local TCP interface.
            let interfaceRepo = InterfaceRepository()
            if let tcpEntity = interfaceRepo.getEnabledInterfaces().first(where: { $0.type == .tcpClient }),
               case .tcpClient(let config) = tcpEntity.config {
                activeInterfaces.append("TCP (\(config.targetHost):\(String(config.targetPort)))")
            } else {
                activeInterfaces.append("TCP")
            }
        }
        if let auto = appServices.autoInterface, await auto.peerCount > 0 {
            let count = await auto.peerCount
            activeInterfaces.append("AutoInterface (\(count) peer\(count == 1 ? "" : "s"))")
        }
        if let rnode = appServices.rnodeInterface, await rnode.state == .connected {
            activeInterfaces.append("RNode")
        }
        if modelB {
            // Model B: BLE runs in the NE — count its native peers (over the proxy
            // IPC) rather than the app's Compat `bleInterface`, which never has peers.
            let bleCount = await appServices.getBLEConnectionInfos().count
            if bleCount > 0 {
                activeInterfaces.append("Bluetooth LE (\(bleCount) peer\(bleCount == 1 ? "" : "s"))")
            }
        } else if let ble = appServices.bleInterface, await ble.state == .connected {
            let count = await ble.peerCount
            if count > 0 {
                activeInterfaces.append("Bluetooth LE (\(count) peer\(count == 1 ? "" : "s"))")
            } else {
                activeInterfaces.append("Bluetooth LE")
            }
        }
        connectedInterface = activeInterfaces.isEmpty ? "No active interface" : activeInterfaces.joined(separator: ", ")

        // Overall state: in Model B "connected" = at least one active interface
        // (the NE relay or an app-owned radio); otherwise defer to the app's own
        // connection tracking (which owns the interfaces in Model A).
        isConnected = modelB ? !activeInterfaces.isEmpty : appServices.isConnected
        isReconnecting = modelB ? false : appServices.isReconnecting
        reconnectError = modelB ? nil : appServices.connectionError
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

    /// Persist the selected RNS backend. Takes effect on the next app launch —
    /// the backend is constructed once at stack init and can't be hot-swapped
    /// live (same constraint as `restartPythonBackend()`), so the UI surfaces a
    /// relaunch hint rather than tearing the stack down mid-session.
    @MainActor
    public func applyBackendSelection() {
        BackendPreference.isSwift = useSwiftBackend
        backendChangePending = true
    }

    // Model B is no longer a user toggle — it's the sole architecture on the
    // Swift build (see `BackendPreference.modelB`). `applyModelBSelection` and
    // the `modelBEnabled` state were removed with the Settings toggle.

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
        // Keep LocalIdentity.displayName in sync so the "Active:" label stays current.
        if let mgr = identityManager, let active = await mgr.getActiveIdentity() {
            await mgr.renameIdentity(active.identityHash, newName: identity.displayName)
        }
        activeIdentityName = identity.displayName
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
            try await appServices.sendAllAnnounces(displayName: identity.displayName)
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
            try await appServices.sendAllAnnounces(displayName: identity.displayName)
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
            // Persist + (Model B) republish the seam so interval/periodic edits reach
            // the NE — including an interval-only change or disabling periodic sync,
            // which the start/stop calls above don't push on their own.
            await propManager.savePreferences()
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

        await propManager.syncNow(userInitiated: true)

        syncProgress = propManager.syncState.progress
        lastSyncTime = propManager.lastSyncTime
        isSyncing = false

        if let error = propManager.syncState.errorDescription {
            syncError = error
        }
    }

    /// Refresh sync time from propagation manager (call on view appear).
    @MainActor
    public func refreshSyncState() {
        if let propManager = appServices.propagationManager {
            lastSyncTime = propManager.lastSyncTime
            selectedRelayName = propManager.selectedNodeName
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
