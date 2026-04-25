//
//  IdentityManager.swift
//  ColumbaApp
//
//  Actor-based service managing multiple local identities.
//  Handles create, switch, rename, delete, and migration from single-identity.
//

import Foundation
import ReticulumSwift
import LXMFSwift
import os.log

/// Manages multiple local identities with per-identity Keychain storage and databases.
@available(macOS 14.0, iOS 17.0, *)
actor IdentityManager {
    // MARK: - Constants

    private static let storageKey = "localIdentities"
    static let keychainService = "com.columba.identity"

    private let logger = Logger(subsystem: "network.columba.Columba", category: "IdentityManager")

    // MARK: - State

    private var identities: [LocalIdentity] = []

    // MARK: - Init

    init() {
        identities = Self.loadIdentities()
    }

    // MARK: - Queries

    /// Returns all stored identities, ordered by lastUsedAt descending.
    func getAllIdentities() -> [LocalIdentity] {
        identities.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// Returns the currently active identity, if any.
    func getActiveIdentity() -> LocalIdentity? {
        identities.first(where: { $0.isActive })
    }

    // MARK: - Create

    /// Create a new identity with the given display name.
    ///
    /// Generates a new Reticulum `Identity`, saves its private keys to Keychain,
    /// and adds a `LocalIdentity` record. The new identity is NOT activated.
    ///
    /// - Parameter displayName: User-facing name for this identity
    /// - Returns: The newly created `LocalIdentity`
    func createIdentity(displayName: String) throws -> LocalIdentity {
        let identity = Identity()
        let identityHash = identity.hexHash

        // Compute LXMF delivery destination hash
        let destHash = Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])
        let destHashHex = destHash.map { String(format: "%02x", $0) }.joined()

        // Save private keys to Keychain
        let account = "identity-\(identityHash)"
        try identity.saveToKeychain(service: Self.keychainService, account: account)

        let now = Date().timeIntervalSince1970
        let local = LocalIdentity(
            identityHash: identityHash,
            displayName: displayName,
            destinationHash: destHashHex,
            createdAt: now,
            lastUsedAt: now,
            isActive: false
        )

        identities.append(local)
        saveIdentities()

        logger.info("Created identity '\(displayName)': \(identityHash)")
        return local
    }

    // MARK: - Load Keys

    /// Load the Reticulum `Identity` (private keys) for a given identity hash.
    ///
    /// - Parameter hash: The identity hash hex string
    /// - Returns: The reconstructed `Identity` with private keys
    func loadIdentityKeys(for hash: String) throws -> Identity {
        let account = "identity-\(hash)"
        guard let identity = try Identity.loadFromKeychain(
            service: Self.keychainService,
            account: account
        ) else {
            throw IdentityManagerError.keychainLoadFailed(hash)
        }
        return identity
    }

    // MARK: - Switch

    /// Switch to the identity with the given hash.
    ///
    /// Marks all identities inactive, activates the target, loads its keys.
    ///
    /// - Parameter hash: The identity hash to switch to
    /// - Returns: Tuple of (LocalIdentity metadata, Identity keys)
    func switchToIdentity(_ hash: String) throws -> (LocalIdentity, Identity) {
        guard let idx = identities.firstIndex(where: { $0.identityHash == hash }) else {
            throw IdentityManagerError.identityNotFound(hash)
        }

        let identity = try loadIdentityKeys(for: hash)

        // Deactivate all, activate target
        for i in identities.indices {
            identities[i].isActive = false
        }
        identities[idx].isActive = true
        identities[idx].lastUsedAt = Date().timeIntervalSince1970

        saveIdentities()

        logger.info("Switched to identity: \(hash)")
        return (identities[idx], identity)
    }

    // MARK: - Rename

    /// Rename an identity.
    func renameIdentity(_ hash: String, newName: String) {
        guard let idx = identities.firstIndex(where: { $0.identityHash == hash }) else { return }
        identities[idx].displayName = newName
        saveIdentities()
        logger.info("Renamed identity \(hash) to '\(newName)'")
    }

    // MARK: - Delete

    /// Delete a non-active identity.
    ///
    /// Removes Keychain entry and LXMF database file.
    /// Refuses to delete the currently active identity.
    func deleteIdentity(_ hash: String) throws {
        guard let idx = identities.firstIndex(where: { $0.identityHash == hash }) else {
            throw IdentityManagerError.identityNotFound(hash)
        }

        if identities[idx].isActive {
            throw IdentityManagerError.cannotDeleteActive
        }

        let local = identities[idx]

        // Remove Keychain entry
        let account = local.keychainAccount
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Remove database file
        let dbPath = Self.databasePath(for: local.databaseFilename)
        try? FileManager.default.removeItem(atPath: dbPath)

        identities.remove(at: idx)
        saveIdentities()

        logger.info("Deleted identity: \(hash)")
    }

    // MARK: - Migration

    /// Migrate from the old single-identity storage to multi-identity.
    ///
    /// Checks for an existing identity in the old Keychain location and converts
    /// it into a `LocalIdentity` record. Renames the old `lxmf.db` to `lxmf_{hash}.db`.
    func migrateFromSingleIdentityIfNeeded(settingsRepository: SettingsRepository) async {
        // Already migrated?
        if !identities.isEmpty { return }

        let oldAccount = "reticulum-identity"

        // Try loading from old Keychain location
        guard let oldIdentity = try? Identity.loadFromKeychain(
            service: Self.keychainService,
            account: oldAccount
        ) else {
            logger.info("No existing single identity to migrate")
            return
        }

        let hash = oldIdentity.hexHash
        let newAccount = "identity-\(hash)"

        // Re-save under new account name
        do {
            try oldIdentity.saveToKeychain(service: Self.keychainService, account: newAccount)
        } catch {
            logger.error("Migration: failed to re-save identity to Keychain: \(error)")
            return
        }

        // Compute destination hash
        let destHash = Destination.hash(identity: oldIdentity, appName: "lxmf", aspects: ["delivery"])
        let destHashHex = destHash.map { String(format: "%02x", $0) }.joined()

        // Load display name from settings
        let displayName = await settingsRepository.getDisplayName()

        // Rename lxmf.db to lxmf_{hash}.db
        let columbaDir = Self.columbaDirectory
        let oldDbPath = columbaDir + "/lxmf.db"
        let newDbPath = columbaDir + "/lxmf_\(hash).db"
        if FileManager.default.fileExists(atPath: oldDbPath) {
            do {
                try FileManager.default.moveItem(atPath: oldDbPath, toPath: newDbPath)
                logger.info("Migration: renamed lxmf.db -> lxmf_\(hash).db")
            } catch {
                logger.warning("Migration: failed to rename DB: \(error). Copying instead.")
                try? FileManager.default.copyItem(atPath: oldDbPath, toPath: newDbPath)
            }
        }

        let now = Date().timeIntervalSince1970
        let local = LocalIdentity(
            identityHash: hash,
            displayName: displayName.isEmpty ? "Anonymous Peer" : displayName,
            destinationHash: destHashHex,
            createdAt: now,
            lastUsedAt: now,
            isActive: true
        )

        identities = [local]
        saveIdentities()

        logger.info("Migration complete: identity \(hash) migrated from single-identity storage")
    }

    // MARK: - Persistence

    private static func loadIdentities() -> [LocalIdentity] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([LocalIdentity].self, from: data)) ?? []
    }

    private func saveIdentities() {
        guard let data = try? JSONEncoder().encode(identities) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - File Paths

    static var columbaDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Columba", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    static func databasePath(for filename: String) -> String {
        columbaDirectory + "/" + filename
    }
}

// MARK: - Errors

enum IdentityManagerError: Error, LocalizedError {
    case identityNotFound(String)
    case keychainLoadFailed(String)
    case cannotDeleteActive

    var errorDescription: String? {
        switch self {
        case .identityNotFound(let hash):
            return "Identity not found: \(hash)"
        case .keychainLoadFailed(let hash):
            return "Failed to load identity keys from Keychain: \(hash)"
        case .cannotDeleteActive:
            return "Cannot delete the active identity. Switch to another identity first."
        }
    }
}
