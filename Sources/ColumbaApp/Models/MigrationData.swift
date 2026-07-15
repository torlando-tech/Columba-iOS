#if COLUMBA_MIGRATION_ENABLED
//
//  MigrationData.swift
//  ColumbaApp
//
//  Codable data models matching Android MigrationBundle v7 for cross-platform
//  .columba backup format. Enables export/import between iOS and Android.
//

import Foundation
import RNSAPI

/// Top-level migration bundle matching Android's MigrationBundle format.
///
/// Version 7 includes identities, conversations, messages, interfaces, and settings.
/// Serialized as JSON inside an encrypted .columba file.
struct MigrationBundle: Codable {
    /// Format version (must be 7 for cross-platform compat).
    let version: Int

    /// Unix timestamp when the export was created.
    let exportedAt: TimeInterval

    /// Platform that created this export ("iOS" or "Android").
    let platform: String

    /// All local identities with their private keys.
    var identities: [IdentityExport]

    /// All conversation metadata.
    var conversations: [ConversationExport]

    /// All messages with packed LXMF wire data.
    var messages: [MessageExport]

    /// All configured network interfaces.
    var interfaces: [InterfaceExport]

    /// App settings/preferences.
    var settings: SettingsExport

    static let currentVersion = 7

    init(
        identities: [IdentityExport] = [],
        conversations: [ConversationExport] = [],
        messages: [MessageExport] = [],
        interfaces: [InterfaceExport] = [],
        settings: SettingsExport = SettingsExport(preferences: [])
    ) {
        self.version = Self.currentVersion
        self.exportedAt = Date().timeIntervalSince1970
        self.platform = "iOS"
        self.identities = identities
        self.conversations = conversations
        self.messages = messages
        self.interfaces = interfaces
        self.settings = settings
    }
}

// MARK: - Identity Export

/// Exported identity with private key material.
struct IdentityExport: Codable {
    /// Hex hash of the identity public key.
    let identityHash: String

    /// User-facing display name.
    let displayName: String

    /// LXMF delivery destination hash (hex).
    let destinationHash: String

    /// Base64-encoded private key data (64 bytes: 32 sign + 32 encrypt).
    let keyData: String

    /// Unix timestamp when created.
    let createdTimestamp: TimeInterval

    /// Unix timestamp when last used.
    let lastUsedTimestamp: TimeInterval

    /// Whether this was the active identity at export time.
    let isActive: Bool

    /// Profile icon name (MDI icon, optional).
    let iconName: String?

    /// Profile icon foreground color hex (optional).
    let iconForegroundColor: String?

    /// Profile icon background color hex (optional).
    let iconBackgroundColor: String?
}

// MARK: - Conversation Export

/// Exported conversation metadata.
struct ConversationExport: Codable {
    /// Destination hash hex of the peer.
    let peerHash: String

    /// Which identity owns this conversation.
    let identityHash: String

    /// Peer display name (optional).
    let peerName: String?

    /// Last message preview text (optional).
    let lastMessage: String?

    /// Timestamp of last message.
    let lastMessageTimestamp: TimeInterval

    /// Number of unread messages.
    let unreadCount: Int

    /// Whether this conversation is favorited.
    let isFavorite: Bool

    /// Peer profile icon name (optional).
    let iconName: String?

    /// Peer icon foreground color hex (optional).
    let iconFgColor: String?

    /// Peer icon background color hex (optional).
    let iconBgColor: String?
}

// MARK: - Message Export

/// Exported message with full packed LXMF wire format.
///
/// Messages are stored as Base64-encoded packed LXMF data to preserve
/// signatures, stamps, and all wire-format fields without re-serialization.
struct MessageExport: Codable {
    /// Message ID hex (SHA-256 hash, 32 bytes).
    let id: String

    /// Conversation destination hash hex.
    let conversationHash: String

    /// Which identity owns this message.
    let identityHash: String

    /// Message timestamp.
    let timestamp: TimeInterval

    /// True if this is an incoming message.
    let isIncoming: Bool

    /// Message delivery-state string (matches `MessageRecord.state`).
    let state: String

    /// Delivery-method string (matches `MessageRecord.method`).
    let method: String

    /// Base64-encoded message body bytes (`MessageRecord.content`). Carried
    /// explicitly because `packedLxmf` only holds the field map, not the text.
    let content: String

    /// Sender destination hash hex (`MessageRecord.sourceHash`).
    let sourceHash: String

    /// Base64-encoded MessagePack field map (attachments, icon, reactions) —
    /// exactly what `LXMFDatabase.getMessageRecords` returns in `packedLxmf`.
    let packedLxmf: String
}

// MARK: - Interface Export

/// Exported network interface configuration.
struct InterfaceExport: Codable {
    /// Interface name.
    let name: String

    /// Interface type raw value (e.g., "TCPClient").
    let type: String

    /// Whether the interface is enabled.
    let enabled: Bool

    /// JSON string of the type-specific config.
    let configJson: String

    /// Display order in the list.
    let displayOrder: Int
}

// MARK: - Settings Export

/// Exported app settings as key-value pairs.
struct SettingsExport: Codable {
    var preferences: [PreferenceEntry]
}

/// A single settings preference entry.
struct PreferenceEntry: Codable {
    /// Setting key name.
    let key: String

    /// Value type: "bool", "string", "double", "int".
    let type: String

    /// String representation of the value.
    let value: String

    static func bool(_ key: String, _ value: Bool) -> PreferenceEntry {
        PreferenceEntry(key: key, type: "bool", value: value ? "true" : "false")
    }

    static func string(_ key: String, _ value: String) -> PreferenceEntry {
        PreferenceEntry(key: key, type: "string", value: value)
    }

    static func double(_ key: String, _ value: Double) -> PreferenceEntry {
        PreferenceEntry(key: key, type: "double", value: String(value))
    }

    static func int(_ key: String, _ value: Int) -> PreferenceEntry {
        PreferenceEntry(key: key, type: "int", value: String(value))
    }
}

// MARK: - Export Preview

/// Summary of data available for export (shown before password entry).
struct ExportPreview {
    let identityCount: Int
    let conversationCount: Int
    let messageCount: Int
    let interfaceCount: Int
}

// MARK: - Import Preview

/// Summary of data in a backup file (shown before import).
struct MigrationPreview {
    let version: Int
    let exportedAt: Date
    let platform: String
    let identityNames: [String]
    let identityCount: Int
    let conversationCount: Int
    let messageCount: Int
    let interfaceCount: Int
    let settingsCount: Int
}

// MARK: - Import Result

/// Counts of imported items after a successful import.
struct ImportResult {
    let identitiesImported: Int
    let identitiesSkipped: Int
    let conversationsImported: Int
    let messagesImported: Int
    let messagesSkipped: Int
    let interfacesImported: Int
    let settingsImported: Int
}
#endif
