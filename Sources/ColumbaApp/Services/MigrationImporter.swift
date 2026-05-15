#if COLUMBA_MIGRATION_ENABLED
//
//  MigrationImporter.swift
//  ColumbaApp
//
//  Reads .columba backup files, decrypts them, and restores data into
//  the app's Keychain, databases, and settings.
//

import Foundation
import os.log

/// Imports data from an encrypted .columba backup file.
@available(macOS 14.0, iOS 17.0, *)
actor MigrationImporter {
    private let identityManager: IdentityManager
    private let settingsRepository: SettingsRepository
    private let logger = Logger(subsystem: "network.columba.Columba", category: "MigrationImporter")

    init(identityManager: IdentityManager, settingsRepository: SettingsRepository) {
        self.identityManager = identityManager
        self.settingsRepository = settingsRepository
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
        let existingHashes = Set(existingIdentities.map { $0.identityHash })

        for export in bundle.identities {
            if existingHashes.contains(export.identityHash) {
                logger.info("Skipping existing identity: \(export.identityHash)")
                identitiesSkipped += 1
                continue
            }

            do {
                // Decode private key data
                guard let keyData = Data(base64Encoded: export.keyData), keyData.count == 64 else {
                    logger.warning("Invalid key data for identity \(export.identityHash)")
                    continue
                }

                // Create Identity from private keys
                let identity = try Identity(privateKeyBytes: keyData)

                // Save to Keychain
                let account = "identity-\(export.identityHash)"
                try identity.saveToKeychain(
                    service: IdentityManager.keychainService,
                    account: account
                )

                // Create LocalIdentity record
                // We don't go through IdentityManager.createIdentity() because
                // we already have the keys and don't want new ones generated
                let local = LocalIdentity(
                    identityHash: export.identityHash,
                    displayName: export.displayName,
                    destinationHash: export.destinationHash,
                    createdAt: export.createdTimestamp,
                    lastUsedAt: export.lastUsedTimestamp,
                    isActive: false // Don't auto-activate imported identities
                )

                // Add to the identity manager's storage directly
                await addIdentityRecord(local)
                identitiesImported += 1
                logger.info("Imported identity: \(export.identityHash) (\(export.displayName))")
            } catch {
                logger.warning("Failed to import identity \(export.identityHash): \(error)")
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

                    // Decode packed LXMF
                    guard let packedData = Data(base64Encoded: msg.packedLxmf) else {
                        logger.warning("Invalid Base64 for message \(msg.id)")
                        continue
                    }

                    // Reconstruct LXMessage from packed wire format
                    do {
                        var lxMessage = try LXMessage.unpackFromBytes(packedData)
                        lxMessage.incoming = msg.isIncoming

                        // Pack and save through normal path
                        _ = try lxMessage.pack()
                        try await db.saveMessage(lxMessage)
                        messagesImported += 1
                    } catch {
                        logger.warning("Failed to import message \(msg.id): \(error)")
                    }
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
        let existingInterfaceNames = Set(repo.interfaces.map { "\($0.name)_\($0.type.rawValue)" })
        let decoder = JSONDecoder()

        for export in bundle.interfaces {
            let key = "\(export.name)_\(export.type)"
            if existingInterfaceNames.contains(key) {
                continue
            }

            guard let ifaceType = InterfaceType(rawValue: export.type) else { continue }

            // Decode config from JSON
            guard let configData = export.configJson.data(using: .utf8),
                  let config = try? decoder.decode(InterfaceTypeConfig.self, from: configData) else {
                continue
            }

            let entity = InterfaceEntity(
                name: export.name,
                type: ifaceType,
                enabled: export.enabled,
                config: config,
                displayOrder: export.displayOrder
            )
            repo.addInterface(entity)
            interfacesImported += 1
        }
        onProgress(0.8)

        // 4. Import settings
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
        onProgress(1.0)

        let result = ImportResult(
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

    /// Add an identity record to IdentityManager's stored list.
    ///
    /// This bypasses the normal createIdentity flow since we already have keys.
    private func addIdentityRecord(_ local: LocalIdentity) async {
        // Load current identities from UserDefaults, append, and save
        let storageKey = "localIdentities"
        var identities: [LocalIdentity] = []

        if let data = UserDefaults.standard.data(forKey: storageKey) {
            identities = (try? JSONDecoder().decode([LocalIdentity].self, from: data)) ?? []
        }

        // Don't add duplicates
        if identities.contains(where: { $0.identityHash == local.identityHash }) {
            return
        }

        identities.append(local)

        if let data = try? JSONEncoder().encode(identities) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// Note: Data(hexString:) extension is defined in PropagationNodeManager.swift
#endif
