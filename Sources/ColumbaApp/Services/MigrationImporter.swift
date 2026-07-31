#if COLUMBA_MIGRATION_ENABLED
//
//  MigrationImporter.swift
//  ColumbaApp
//
//  Reads .columba backup files, decrypts them, and restores data into
//  the app's Keychain, databases, and settings.
//

import Foundation
import RNSAPI
import os.log

struct ValidatedIdentityImport {
    let export: IdentityExport
    let identity: Identity
    let identityHash: String
    let destinationHash: String
}

enum MigrationIdentityValidationError: Error, LocalizedError {
    case invalidKeyData
    case identityHashMismatch
    case destinationHashMismatch
    case duplicateIdentity(String)
    case nonCanonicalIdentityOwner(String)
    case unknownIdentityOwner(String)

    var errorDescription: String? {
        switch self {
        case .invalidKeyData:
            return "Backup identity contains invalid private key data."
        case .identityHashMismatch:
            return "Backup identity hash does not match its private keys."
        case .destinationHashMismatch:
            return "Backup destination hash does not match its private keys."
        case .duplicateIdentity(let hash):
            return "Backup contains duplicate identity \(hash)."
        case .nonCanonicalIdentityOwner(let hash):
            return "Backup history uses a non-canonical identity hash: \(hash)."
        case .unknownIdentityOwner(let hash):
            return "Backup history references an identity not contained in the backup: \(hash)."
        }
    }
}

enum MigrationInterfaceValidationError: Error, LocalizedError {
    case unsupportedMode(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedMode(let mode):
            return "Backup interface uses an unsupported mode: \(mode)."
        }
    }
}

/// Imports data from an encrypted .columba backup file.
@available(macOS 14.0, iOS 17.0, *)
actor MigrationImporter {
    private let identityManager: IdentityManager
    private let settingsRepository: SettingsRepository
    private let appServices: AppServices?
    private let logger = Logger(subsystem: "network.columba.Columba", category: "MigrationImporter")

    init(
        identityManager: IdentityManager,
        settingsRepository: SettingsRepository,
        appServices: AppServices? = nil
    ) {
        self.identityManager = identityManager
        self.settingsRepository = settingsRepository
        self.appServices = appServices
    }

    /// Validate every restored identity before the importer performs any durable write.
    /// Supplied metadata is never authoritative: hashes must be derived from key material.
    static func validateIdentityExports(_ exports: [IdentityExport]) throws -> [ValidatedIdentityImport] {
        var seenHashes = Set<String>()
        return try exports.map { export in
            guard let keyData = Data(base64Encoded: export.keyData), keyData.count == 64 else {
                throw MigrationIdentityValidationError.invalidKeyData
            }
            let identity = try Identity(privateKeyBytes: keyData)
            let identityHash = identity.hexHash.lowercased()
            let destinationHash = Destination.hash(
                identity: identity,
                appName: "lxmf",
                aspects: ["delivery"]
            ).map { String(format: "%02x", $0) }.joined()

            guard export.identityHash.lowercased() == identityHash else {
                throw MigrationIdentityValidationError.identityHashMismatch
            }
            guard export.destinationHash.lowercased() == destinationHash else {
                throw MigrationIdentityValidationError.destinationHashMismatch
            }
            guard seenHashes.insert(identityHash).inserted else {
                throw MigrationIdentityValidationError.duplicateIdentity(identityHash)
            }
            return ValidatedIdentityImport(
                export: export,
                identity: identity,
                identityHash: identityHash,
                destinationHash: destinationHash
            )
        }
    }

    static func preferredIdentityHash(from identities: [ValidatedIdentityImport]) -> String? {
        identities.first(where: { $0.export.isActive })?.identityHash
            ?? identities.first?.identityHash
    }

    static func validateRecordOwnerHashes(
        _ ownerHashes: [String],
        canonicalIdentityHashes: Set<String>
    ) throws {
        for ownerHash in ownerHashes {
            let canonical = ownerHash.lowercased()
            guard ownerHash == canonical else {
                throw MigrationIdentityValidationError.nonCanonicalIdentityOwner(ownerHash)
            }
            guard canonicalIdentityHashes.contains(canonical) else {
                throw MigrationIdentityValidationError.unknownIdentityOwner(ownerHash)
            }
        }
    }

    static func validatedInterfaceMode(_ rawMode: String?) throws -> InterfaceMode {
        guard let rawMode else { return .full }
        guard let mode = InterfaceMode(rawValue: rawMode) else {
            throw MigrationInterfaceValidationError.unsupportedMode(rawMode)
        }
        return mode
    }

    // MARK: - Format Detection

    /// Check if data is an encrypted .columba file.
    nonisolated func isEncrypted(_ data: Data) -> Bool {
        MigrationCrypto.isEncrypted(data)
    }

    // MARK: - Preview

    /// Decrypt and preview backup contents without importing.
    ///
    /// - Parameters:
    ///   - data: Raw .columba file data
    ///   - password: Decryption password (nil if unencrypted)
    /// - Returns: Preview of the backup contents
    func previewMigration(data: Data, password: String?) async throws -> MigrationPreview {
        let bundle = try decryptAndParse(data: data, password: password)

        return MigrationPreview(
            version: bundle.version,
            exportedAt: Date(timeIntervalSince1970: bundle.exportedAt),
            platform: bundle.platform,
            identityNames: bundle.identities.map { $0.displayName },
            identityCount: bundle.identities.count,
            conversationCount: bundle.conversations.count,
            messageCount: bundle.messages.count,
            interfaceCount: bundle.interfaces.count,
            settingsCount: bundle.settings.preferences.count
        )
    }

    // MARK: - Import

    /// Import all data from a .columba backup file.
    ///
    /// - Parameters:
    ///   - data: Raw .columba file data
    ///   - password: Decryption password (nil if unencrypted)
    ///   - onProgress: Progress callback (0.0 to 1.0)
    /// - Returns: Summary of imported items
    func importData(data: Data, password: String?, onProgress: @Sendable (Float) -> Void) async throws -> ImportResult {
        let bundle = try decryptAndParse(data: data, password: password)
        let validatedIdentities = try Self.validateIdentityExports(bundle.identities)
        let canonicalIdentityHashes = Set(validatedIdentities.map(\.identityHash))
        try Self.validateRecordOwnerHashes(
            bundle.conversations.map(\.identityHash) + bundle.messages.map(\.identityHash),
            canonicalIdentityHashes: canonicalIdentityHashes
        )
        let validatedInterfaceModes = try bundle.interfaces.map { try Self.validatedInterfaceMode($0.mode) }
        onProgress(0.1)

        var identitiesImported = 0
        var identitiesSkipped = 0
        var conversationsImported = 0
        var messagesImported = 0
        var messagesSkipped = 0
        var interfacesImported = 0
        var settingsImported = 0

        // 1. Import identities
        let existingIdentities = await identityManager.getAllIdentities()
        let existingHashes = Set(existingIdentities.map { $0.identityHash.lowercased() })

        for validated in validatedIdentities {
            let export = validated.export
            if existingHashes.contains(validated.identityHash) {
                logger.info("Skipping existing identity: \(validated.identityHash)")
                identitiesSkipped += 1
                continue
            }

            do {
                // Store and register only canonical hashes derived from private keys.
                let account = "identity-\(validated.identityHash)"
                try validated.identity.saveToKeychain(
                    service: IdentityManager.keychainService,
                    account: account
                )

                let local = LocalIdentity(
                    identityHash: validated.identityHash,
                    displayName: export.displayName,
                    destinationHash: validated.destinationHash,
                    createdAt: export.createdTimestamp,
                    lastUsedAt: export.lastUsedTimestamp,
                    isActive: false // Don't auto-activate imported identities
                )

                // Register through the actor-owned cache so a subsequent create/switch
                // cannot overwrite freshly restored metadata from stale in-memory state.
                try await identityManager.importIdentityRecord(local)
                identitiesImported += 1
                logger.info("Imported identity: \(validated.identityHash) (\(export.displayName))")
            } catch {
                logger.error("Failed to persist restored identity \(validated.identityHash): \(error)")
                // History import must not continue without accessible key material and metadata.
                throw error
            }
        }
        onProgress(0.3)

        // 2. Import conversations + messages per identity
        // Group conversations and messages by identity
        let conversationsByIdentity = Dictionary(grouping: bundle.conversations) { $0.identityHash }
        let messagesByIdentity = Dictionary(grouping: bundle.messages) { $0.identityHash }

        let allIdentityHashes = Set(
            bundle.conversations.map { $0.identityHash } +
            bundle.messages.map { $0.identityHash }
        )

        for (idx, identityHash) in allIdentityHashes.enumerated() {
            let dbFilename = "lxmf_\(identityHash).db"
            let dbPath = IdentityManager.databasePath(for: dbFilename)

            do {
                let db = try LXMFDatabase(path: dbPath)

                // Import conversations
                let convs = conversationsByIdentity[identityHash] ?? []
                for conv in convs {
                    guard let peerHash = Data(hexString: conv.peerHash) else { continue }

                    // Ensure conversation exists (upsert)
                    try await db.ensureConversation(hash: peerHash, displayName: conv.peerName)

                    // Update icon if present
                    if let iconName = conv.iconName,
                       let fg = conv.iconFgColor,
                       let bg = conv.iconBgColor {
                        try await db.updatePeerIcon(
                            peerHash,
                            iconName: iconName,
                            fgColor: fg,
                            bgColor: bg
                        )
                    }

                    // Set favorite
                    if conv.isFavorite {
                        try await db.setFavorite(hash: peerHash, isFavorite: true)
                    }

                    // Reconcile list-preview metadata from the backup. Messages
                    // are restored via saveMessageRecord, which does NOT touch an
                    // existing conversation row, so without this the restored
                    // conversation keeps a blank preview, no timestamp (wrong
                    // ordering), and a zero unread count.
                    let lastAt = conv.lastMessageTimestamp > 0
                        ? Date(timeIntervalSince1970: conv.lastMessageTimestamp)
                        : nil
                    try await db.setConversationMetadata(
                        hash: peerHash,
                        lastMessage: conv.lastMessage,
                        lastMessageAt: lastAt,
                        unreadCount: conv.unreadCount
                    )

                    conversationsImported += 1
                }

                // Import messages
                let msgs = messagesByIdentity[identityHash] ?? []
                for msg in msgs {
                    guard let msgId = Data(hexString: msg.id) else { continue }

                    // Skip duplicates
                    if try await db.hasMessage(id: msgId) {
                        messagesSkipped += 1
                        continue
                    }

                    // Decode the MessagePack field map (attachments/icon/reactions).
                    let packedData = Data(base64Encoded: msg.packedLxmf) ?? Data()

                    // Persist the record directly. `LXMessage.unpackFromBytes`/
                    // `pack()` are Compat stubs that return an empty placeholder
                    // (zeroed hash, no content), so round-tripping through them
                    // would silently corrupt the restored message with blank
                    // content. Rebuild the MessageRecord from the export instead.
                    let record = MessageRecord(
                        id: msgId,
                        conversationHash: Data(hexString: msg.conversationHash) ?? Data(),
                        content: Data(base64Encoded: msg.content) ?? Data(),
                        timestamp: msg.timestamp,
                        direction: msg.isIncoming ? .inbound : .outbound,
                        state: msg.state,
                        messageId: msgId,
                        sourceHash: Data(hexString: msg.sourceHash) ?? Data(),
                        method: msg.method,
                        packedLxmf: packedData
                    )
                    db.saveMessageRecord(record)
                    messagesImported += 1
                }
            } catch {
                logger.warning("Failed to import data for identity \(identityHash): \(error)")
            }

            let progress = Float(idx + 1) / Float(max(allIdentityHashes.count, 1))
            onProgress(0.3 + progress * 0.4)
        }

        // 3. Import interfaces
        onProgress(0.7)
        let repo = InterfaceRepository()
        var seenInterfaces = repo.interfaces
        let decoder = JSONDecoder()

        for (export, mode) in zip(bundle.interfaces, validatedInterfaceModes) {
            guard let ifaceType = InterfaceType(rawValue: export.type) else { continue }

            // Mode was added after the initial backup format; validated legacy
            // records default to full while explicit unsupported values fail preflight.
            guard let configData = export.configJson.data(using: .utf8),
                  let config = try? decoder.decode(InterfaceTypeConfig.self, from: configData) else {
                continue
            }

            let entity = InterfaceEntity(
                name: export.name,
                type: ifaceType,
                enabled: export.enabled,
                mode: mode,
                config: config,
                displayOrder: export.displayOrder
            )
            if seenInterfaces.contains(where: {
                $0.type == entity.type && $0.mode == entity.mode && $0.config == entity.config
            }) {
                continue
            }
            repo.addInterface(entity)
            seenInterfaces.append(entity)
            interfacesImported += 1
        }
        onProgress(0.8)

        // 4. Import settings
        var importedIncomingMessageSizeLimit = false
        for pref in bundle.settings.preferences {
            switch pref.key {
            case "displayName":
                let current = await settingsRepository.getDisplayName()
                if current.isEmpty {
                    await settingsRepository.setDisplayName(pref.value)
                    settingsImported += 1
                }
            case "defaultDeliveryMethod":
                await settingsRepository.setDefaultDeliveryMethod(pref.value)
                settingsImported += 1
            case "retryViaRelay":
                await settingsRepository.setRetryViaRelay(pref.value == "true")
                settingsImported += 1
            case "autoSelectRelay":
                await settingsRepository.setAutoSelectRelay(pref.value == "true")
                settingsImported += 1
            case "periodicSyncEnabled":
                await settingsRepository.setPeriodicSyncEnabled(pref.value == "true")
                settingsImported += 1
            case "syncIntervalSeconds":
                if let interval = Double(pref.value) {
                    await settingsRepository.setSyncInterval(interval)
                    settingsImported += 1
                }
            case "incoming_message_size_limit_kb":
                if let value = Int(pref.value) {
                    await settingsRepository.setIncomingMessageSizeLimitKB(value)
                    importedIncomingMessageSizeLimit = true
                    settingsImported += 1
                }
            case "auto_announce_enabled":
                UserDefaults.standard.set(pref.value == "true", forKey: "auto_announce_enabled")
                settingsImported += 1
            case "announce_interval_hours":
                if let hours = Int(pref.value) {
                    UserDefaults.standard.set(hours, forKey: "announce_interval_hours")
                    settingsImported += 1
                }
            case "notifications_enabled":
                UserDefaults.standard.set(pref.value == "true", forKey: "notifications_enabled")
                settingsImported += 1
            case "show_message_previews":
                UserDefaults.standard.set(pref.value == "true", forKey: "show_message_previews")
                settingsImported += 1
            case "play_sounds":
                UserDefaults.standard.set(pref.value == "true", forKey: "play_sounds")
                settingsImported += 1
            case "block_unknown_senders":
                UserDefaults.standard.set(pref.value == "true", forKey: "block_unknown_senders")
                settingsImported += 1
            default:
                break
            }
        }
        if importedIncomingMessageSizeLimit {
            await appServices?.applyIncomingMessageSizeLimitFromSettings()
        }
        onProgress(1.0)

        let preferredIdentityHash = Self.preferredIdentityHash(from: validatedIdentities)
        let result = ImportResult(
            preferredIdentityHash: preferredIdentityHash,
            identitiesImported: identitiesImported,
            identitiesSkipped: identitiesSkipped,
            conversationsImported: conversationsImported,
            messagesImported: messagesImported,
            messagesSkipped: messagesSkipped,
            interfacesImported: interfacesImported,
            settingsImported: settingsImported
        )

        logger.info("Import complete: \(identitiesImported) identities, \(messagesImported) messages, \(interfacesImported) interfaces")
        return result
    }

    // MARK: - Private Helpers

    /// Decrypt (if needed) and parse a .columba file into a MigrationBundle.
    private func decryptAndParse(data: Data, password: String?) throws -> MigrationBundle {
        let jsonData: Data

        if MigrationCrypto.isEncrypted(data) {
            guard let password = password, !password.isEmpty else {
                throw MigrationCryptoError.passwordRequired
            }
            jsonData = try MigrationCrypto.decrypt(data: data, password: password)
        } else if MigrationCrypto.isZip(data) {
            // ZIP format (Android exports with attachments) — extract manifest.json
            // For now, treat as unsupported since we'd need ZIP decompression
            throw MigrationCryptoError.invalidFormat
        } else {
            // Assume unencrypted JSON
            jsonData = data
        }

        let decoder = JSONDecoder()
        let bundle = try decoder.decode(MigrationBundle.self, from: jsonData)

        guard bundle.version <= MigrationBundle.currentVersion else {
            throw MigrationCryptoError.invalidFormat
        }

        return bundle
    }

}

// Note: Data(hexString:) extension is defined in PropagationNodeManager.swift
#endif
