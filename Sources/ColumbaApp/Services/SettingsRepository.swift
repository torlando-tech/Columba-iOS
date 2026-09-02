//
//  SettingsRepository.swift
//  ColumbaApp
//
//  UserDefaults-backed settings storage with App Group support.
//  Provides shared configuration between app and Network Extension.
//

import Foundation
import RNSAPI

/// Actor for thread-safe settings access.
///
/// Uses App Group UserDefaults for data sharing between main app
/// and Network Extension. Stores server configuration and identity info.
public actor SettingsRepository {
    public enum MessageTextScale {
        public static let minimum = 0.7
        public static let defaultValue = 1.0
        public static let maximum = 2.0
        public static let step = 0.1

        public static func normalize(_ value: Double?) -> Double {
            guard let value, value.isFinite else { return defaultValue }
            let clamped = min(max(value, minimum), maximum)
            return (clamped / step).rounded() * step
        }
    }

    public enum IncomingMessageSizeLimit {
        public static let minimumKB = 512
        public static let defaultKB = 1_024
        public static let unlimitedKB = 131_072

        public static func normalize(_ valueKB: Int?) -> Int {
            guard let valueKB else { return defaultKB }
            return min(max(valueKB, minimumKB), unlimitedKB)
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let identityFingerprint = "identityFingerprint"
        static let displayName = "displayName"
        static let defaultDeliveryMethod = "defaultDeliveryMethod"
        static let retryViaRelay = "retryViaRelay"
        static let autoSelectRelay = "autoSelectRelay"
        static let manualRelayHash = "manualRelayHash"
        static let manualRelayDeliveryHash = "manualRelayDeliveryHash"
        static let manualRelayName = "manualRelayName"
        static let manualRelayStampCost = "manualRelayStampCost"
        static let periodicSyncEnabled = "periodicSyncEnabled"
        static let syncIntervalSeconds = "syncIntervalSeconds"
        static let lastSyncTimestamp = "lastSyncTimestamp"
        static let incomingMessageSizeLimitKB = "incoming_message_size_limit_kb"
        static let messageTextScale = "message_text_scale"
        static let iconName = "profileIconName"
        static let iconFgColor = "profileIconFgColor"
        static let iconBgColor = "profileIconBgColor"
    }

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    /// Create settings repository with App Group UserDefaults.
    public init() {
        // Use App Group UserDefaults for sharing with Network Extension
        // Falls back to standard UserDefaults if App Group not available
        self.defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    // MARK: - Identity

    /// Get the identity fingerprint.
    ///
    /// The fingerprint is a hex-encoded hash of the Reticulum identity
    /// public key. This is populated by the Network Extension when it
    /// initializes the identity.
    ///
    /// - Returns: Identity fingerprint hex string, or "Not configured" if not set
    public func getIdentityFingerprint() -> String {
        defaults.string(forKey: Keys.identityFingerprint) ?? "Not configured"
    }

    /// Set the identity fingerprint.
    ///
    /// Called by Network Extension after identity initialization.
    ///
    /// - Parameter fingerprint: Hex-encoded identity hash
    public func setIdentityFingerprint(_ fingerprint: String) {
        defaults.set(fingerprint, forKey: Keys.identityFingerprint)
    }

    // MARK: - Display Name

    /// The display name shown to peers when the user has not set one.
    /// Single source of truth for the "Anonymous Peer" default; previously this
    /// literal was duplicated across IdentityManager, OnboardingViewModel, and
    /// the startup path with slightly different empty-guards.
    public static let defaultDisplayName = "Anonymous Peer"

    /// Get the display name for announces.
    ///
    /// This name is broadcast to the network when announcing,
    /// allowing other users to identify this device.
    ///
    /// - Returns: Display name, or empty string if not set
    public func getDisplayName() -> String {
        defaults.string(forKey: Keys.displayName) ?? ""
    }

    /// The display name to broadcast on announce, applying the default fallback.
    ///
    /// Returns the configured name trimmed of surrounding whitespace, or
    /// `defaultDisplayName` when none is set (or only whitespace). This is the
    /// single point that guarantees the startup / auto / manual announce paths
    /// never emit a nameless LXMF announce - an empty `getDisplayName()` value
    /// forwarded to `register_delivery_identity` is exactly the
    /// "announced without a display name" bug.
    public func resolveDisplayName() -> String {
        let name = (defaults.string(forKey: Keys.displayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? Self.defaultDisplayName : name
    }

    /// Set the display name for announces.
    ///
    /// - Parameter name: Display name to broadcast when announcing
    public func setDisplayName(_ name: String) {
        defaults.set(name, forKey: Keys.displayName)
    }

    // MARK: - Delivery & Propagation

    /// Get the default outbound delivery method ("direct" or "propagated").
    public func getDefaultDeliveryMethod() -> String {
        defaults.string(forKey: Keys.defaultDeliveryMethod) ?? "direct"
    }

    /// Set default delivery method.
    public func setDefaultDeliveryMethod(_ method: String) {
        defaults.set(method, forKey: Keys.defaultDeliveryMethod)
    }

    /// Get whether to retry failed direct sends via relay.
    public func getRetryViaRelay() -> Bool {
        guard defaults.object(forKey: Keys.retryViaRelay) != nil else {
            return true
        }
        return defaults.bool(forKey: Keys.retryViaRelay)
    }

    /// Set whether to retry via relay on direct failure.
    public func setRetryViaRelay(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.retryViaRelay)
    }

    /// Get whether auto-select relay is enabled.
    public func getAutoSelectRelay() -> Bool {
        // Default to true if never set
        if defaults.object(forKey: Keys.autoSelectRelay) == nil { return true }
        return defaults.bool(forKey: Keys.autoSelectRelay)
    }

    /// Set auto-select relay preference.
    public func setAutoSelectRelay(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoSelectRelay)
    }

    /// Get manually selected relay hash (hex string).
    public func getManualRelayHash() -> String? {
        defaults.string(forKey: Keys.manualRelayHash)
    }

    /// Set manually selected relay hash.
    public func setManualRelayHash(_ hashHex: String?) {
        if let hex = hashHex {
            defaults.set(hex, forKey: Keys.manualRelayHash)
        } else {
            defaults.removeObject(forKey: Keys.manualRelayHash)
        }
    }

    /// Get the relay's lxmf.delivery destination hash (hex string).
    public func getManualRelayDeliveryHash() -> String? {
        defaults.string(forKey: Keys.manualRelayDeliveryHash)
    }

    /// Set the relay's lxmf.delivery destination hash.
    public func setManualRelayDeliveryHash(_ hashHex: String?) {
        if let hex = hashHex {
            defaults.set(hex, forKey: Keys.manualRelayDeliveryHash)
        } else {
            defaults.removeObject(forKey: Keys.manualRelayDeliveryHash)
        }
    }

    /// Get saved relay display name.
    public func getManualRelayName() -> String? {
        defaults.string(forKey: Keys.manualRelayName)
    }

    /// Set saved relay display name.
    public func setManualRelayName(_ name: String?) {
        if let name = name {
            defaults.set(name, forKey: Keys.manualRelayName)
        } else {
            defaults.removeObject(forKey: Keys.manualRelayName)
        }
    }

    /// Get the saved relay's proof-of-work stamp cost, or nil if none saved.
    /// Persisted so the Model B App-Group seam carries the correct cost across a
    /// cold start, before the PN's fresh announce re-resolves it.
    public func getManualRelayStampCost() -> Int? {
        defaults.object(forKey: Keys.manualRelayStampCost) as? Int
    }

    /// Set the saved relay's proof-of-work stamp cost.
    public func setManualRelayStampCost(_ cost: Int?) {
        if let cost = cost {
            defaults.set(cost, forKey: Keys.manualRelayStampCost)
        } else {
            defaults.removeObject(forKey: Keys.manualRelayStampCost)
        }
    }

    /// Get whether periodic sync is enabled.
    public func getPeriodicSyncEnabled() -> Bool {
        defaults.bool(forKey: Keys.periodicSyncEnabled)
    }

    /// Set periodic sync preference.
    public func setPeriodicSyncEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.periodicSyncEnabled)
    }

    /// Get sync interval in seconds, clamped to the user-facing minimum.
    public func getSyncInterval() -> TimeInterval {
        let value = defaults.double(forKey: Keys.syncIntervalSeconds)
        let requested = value > 0 ? value : 3600
        return max(15 * 60, requested)
    }

    /// Set sync interval in seconds, clamped to the user-facing minimum.
    public func setSyncInterval(_ interval: TimeInterval) {
        defaults.set(max(15 * 60, interval), forKey: Keys.syncIntervalSeconds)
    }

    // MARK: - Incoming Message Size Limit

    /// Get the inbound packed-message cap in KB, clamped to Android-compatible bounds.
    public func getIncomingMessageSizeLimitKB() -> Int {
        let raw = defaults.object(forKey: Keys.incomingMessageSizeLimitKB)
        let stored: Int?
        switch raw {
        case let value as Int:
            stored = value
        case let value as NSNumber:
            stored = value.intValue
        case let value as String:
            stored = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            stored = nil
        }
        let normalized = IncomingMessageSizeLimit.normalize(stored)
        if normalized != stored {
            defaults.set(normalized, forKey: Keys.incomingMessageSizeLimitKB)
        } else if raw == nil {
            defaults.set(normalized, forKey: Keys.incomingMessageSizeLimitKB)
        }
        return normalized
    }

    /// Persist the inbound packed-message cap in KB.
    public func setIncomingMessageSizeLimitKB(_ valueKB: Int) {
        defaults.set(IncomingMessageSizeLimit.normalize(valueKB), forKey: Keys.incomingMessageSizeLimitKB)
    }

    /// Clear the stored cap so the default is used next read.
    public func clearIncomingMessageSizeLimitKB() {
        defaults.removeObject(forKey: Keys.incomingMessageSizeLimitKB)
    }

    // MARK: - Message Text Scale

    /// Get the global conversation message-body scale using Android-compatible bounds.
    public func getMessageTextScale() -> Double {
        let raw = defaults.object(forKey: Keys.messageTextScale)
        let stored: Double?
        switch raw {
        case let value as NSNumber:
            stored = value.doubleValue
        case let value as String:
            stored = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            stored = nil
        }
        let normalized = MessageTextScale.normalize(stored)
        if raw == nil || stored == nil || normalized != stored {
            defaults.set(normalized, forKey: Keys.messageTextScale)
        }
        return normalized
    }

    /// Persist the global conversation message-body scale in 10% increments.
    public func setMessageTextScale(_ value: Double) {
        defaults.set(MessageTextScale.normalize(value), forKey: Keys.messageTextScale)
    }

    /// Get last sync timestamp.
    public func getLastSyncTimestamp() -> TimeInterval? {
        let value = defaults.double(forKey: Keys.lastSyncTimestamp)
        return value > 0 ? value : nil
    }

    /// Set last sync timestamp.
    public func setLastSyncTimestamp(_ timestamp: TimeInterval) {
        defaults.set(timestamp, forKey: Keys.lastSyncTimestamp)
    }

    // MARK: - Icon Appearance

    /// Get the local user's profile icon appearance.
    ///
    /// - Returns: IconAppearance if set, nil if using identicon
    public func getIconAppearance() -> IconAppearance? {
        guard let name = defaults.string(forKey: Keys.iconName),
              let fg = defaults.string(forKey: Keys.iconFgColor),
              let bg = defaults.string(forKey: Keys.iconBgColor) else {
            return nil
        }
        return IconAppearance(iconName: name, foregroundColor: fg, backgroundColor: bg)
    }

    /// Set the local user's profile icon appearance.
    ///
    /// - Parameter icon: IconAppearance to save, or nil to revert to identicon
    public func setIconAppearance(_ icon: IconAppearance?) {
        if let icon = icon {
            defaults.set(icon.iconName, forKey: Keys.iconName)
            defaults.set(icon.foregroundColor, forKey: Keys.iconFgColor)
            defaults.set(icon.backgroundColor, forKey: Keys.iconBgColor)
        } else {
            defaults.removeObject(forKey: Keys.iconName)
            defaults.removeObject(forKey: Keys.iconFgColor)
            defaults.removeObject(forKey: Keys.iconBgColor)
        }
    }

    // MARK: - Utility

    /// Check if settings have been configured.
    ///
    /// - Returns: True if identity fingerprint is set
    public func isConfigured() -> Bool {
        defaults.string(forKey: Keys.identityFingerprint) != nil
    }

    /// Reset all settings to defaults.
    ///
    /// Removes stored identity fingerprint.
    public func reset() {
        defaults.removeObject(forKey: Keys.identityFingerprint)
    }
}
