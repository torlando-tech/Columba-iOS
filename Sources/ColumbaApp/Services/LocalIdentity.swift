//
//  LocalIdentity.swift
//  ColumbaApp
//
//  Data model for a locally stored identity.
//  Each identity has its own Keychain entry and LXMF database file.
//

import Foundation

/// Represents a locally stored identity with metadata.
///
/// Persisted as a JSON array in UserDefaults under `"localIdentities"`.
/// Each identity maps to:
/// - A Keychain entry at `"identity-{identityHash}"`
/// - An LXMF database at `"lxmf_{identityHash}.db"`
struct LocalIdentity: Codable, Identifiable, Equatable {
    /// Hex hash of the identity (32 chars). Serves as primary key.
    let identityHash: String

    /// User-facing display name (e.g., "Work", "Personal").
    var displayName: String

    /// LXMF delivery destination hash hex (32 chars).
    let destinationHash: String

    /// Unix timestamp when this identity was created.
    let createdAt: TimeInterval

    /// Unix timestamp when this identity was last activated.
    var lastUsedAt: TimeInterval

    /// Whether this identity is the currently active one.
    var isActive: Bool

    var id: String { identityHash }

    /// Keychain account name for storing this identity's private keys.
    var keychainAccount: String { "identity-\(identityHash)" }

    /// Filename for this identity's LXMF database.
    var databaseFilename: String { "lxmf_\(identityHash).db" }
}
