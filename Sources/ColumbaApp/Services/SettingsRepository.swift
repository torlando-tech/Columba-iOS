//
//  SettingsRepository.swift
//  ColumbaApp
//
//  UserDefaults-backed settings storage with App Group support.
//  Provides shared configuration between app and Network Extension.
//

import Foundation

/// Actor for thread-safe settings access.
///
/// Uses App Group UserDefaults for data sharing between main app
/// and Network Extension. Stores relay configuration and identity info.
public actor SettingsRepository {
    // MARK: - Constants

    /// App Group identifier for shared container.
    private static let appGroupSuiteName = "group.com.columba.app"

    /// Default relay address for Reticulum network.
    /// TODO: Change back to "tcp://reticulum.network:4242" for production
    private static let defaultRelayAddress = "127.0.0.1:4242"

    // MARK: - Keys

    private enum Keys {
        static let relayAddress = "relayAddress"
        static let identityFingerprint = "identityFingerprint"
        static let displayName = "displayName"
    }

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    /// Create settings repository with App Group UserDefaults.
    public init() {
        // Use App Group UserDefaults for sharing with Network Extension
        // Falls back to standard UserDefaults if App Group not available
        self.defaults = UserDefaults(suiteName: Self.appGroupSuiteName) ?? .standard
    }

    // MARK: - Relay Configuration

    /// Get the configured relay address.
    ///
    /// - Returns: Relay TCP address (e.g., "tcp://reticulum.network:4242")
    public func getRelayAddress() -> String {
        defaults.string(forKey: Keys.relayAddress) ?? Self.defaultRelayAddress
    }

    /// Set the relay address.
    ///
    /// - Parameter address: Relay TCP address (e.g., "tcp://10.0.0.1:4242")
    public func setRelayAddress(_ address: String) {
        defaults.set(address, forKey: Keys.relayAddress)
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

    /// Get the display name for announces.
    ///
    /// This name is broadcast to the network when announcing,
    /// allowing other users to identify this device.
    ///
    /// - Returns: Display name, or empty string if not set
    public func getDisplayName() -> String {
        defaults.string(forKey: Keys.displayName) ?? ""
    }

    /// Set the display name for announces.
    ///
    /// - Parameter name: Display name to broadcast when announcing
    public func setDisplayName(_ name: String) {
        defaults.set(name, forKey: Keys.displayName)
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
    /// Removes stored relay address and identity fingerprint.
    public func reset() {
        defaults.removeObject(forKey: Keys.relayAddress)
        defaults.removeObject(forKey: Keys.identityFingerprint)
    }
}
