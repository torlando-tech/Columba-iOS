#if COLUMBA_MIGRATION_ENABLED
//
//  MigrationExporter.swift
//  ColumbaApp
//
//  Gathers all app data into a MigrationBundle, encrypts it, and writes
//  to a .columba file for backup/transfer.
//

import Foundation
import RNSAPI
import os.log

/// Exports all app data into an encrypted .columba backup file.
@available(macOS 14.0, iOS 17.0, *)
actor MigrationExporter {
    private let identityManager: IdentityManager
    private let settingsRepository: SettingsRepository
    private let logger = Logger(subsystem: "network.columba.Columba", category: "MigrationExporter")

    init(identityManager: IdentityManager, settingsRepository: SettingsRepository) {
        self.identityManager = identityManager
        self.settingsRepository = settingsRepository
    }

    // MARK: - Preview

    /// Get a preview of what would be exported (counts only).
    func getExportPreview() async throws -> ExportPreview {
        let identities = await identityManager.getAllIdentities()
        var totalConversations = 0
        var totalMessages = 0

        for identity in identities {
            let dbPath = IdentityManager.databasePath(for: identity.databaseFilename)
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            do {
                let db = try LXMFDatabase(path: dbPath)
                let conversations = try await db.getConversations(limit: 10000, offset: 0)
                totalConversations += conversations.count
                for conv in conversations {
                    let messages = try await db.getMessageRecords(
                        forConversation: conv.destinationHash, limit: 100000, offset: 0
                    )
                    totalMessages += messages.count
                }
            } catch {
                logger.warning("Preview: failed to read DB for \(identity.identityHash): \(error)")
            }
        }

        let repo = InterfaceRepository()
        let interfaceCount = repo.totalCount

        return ExportPreview(
            identityCount: identities.count,
            conversationCount: totalConversations,
            messageCount: totalMessages,
            interfaceCount: interfaceCount
        )
    }

    // MARK: - Export

    /// Export all data to an encrypted .columba file.
    ///
    /// - Parameters:
    ///   - password: Encryption password (minimum 8 characters)
    ///   - onProgress: Progress callback (0.0 to 1.0)
    /// - Returns: URL of the temporary .columba file
    func exportData(password: String, onProgress: @Sendable (Float) -> Void) async throws -> URL {
        var bundle = MigrationBundle()

        // 1. Export identities
        onProgress(0.05)
        let identities = await identityManager.getAllIdentities()
        logger.info("Exporting \(identities.count) identities")

        for local in identities {
            do {
                let keys = try await identityManager.loadIdentityKeys(for: local.identityHash)
                let keyData = try keys.exportPrivateKeys()

                // Load icon appearance from settings if this is the active identity
                var iconName: String? = nil
                var iconFg: String? = nil
                var iconBg: String? = nil
                if local.isActive {
                    let icon = await settingsRepository.getIconAppearance()
                    iconName = icon?.iconName
                    iconFg = icon?.foregroundColor
                    iconBg = icon?.backgroundColor
                }

                bundle.identities.append(IdentityExport(
                    identityHash: local.identityHash,
                    displayName: local.displayName,
                    destinationHash: local.destinationHash,
                    keyData: keyData.base64EncodedString(),
                    createdTimestamp: local.createdAt,
                    lastUsedTimestamp: local.lastUsedAt,
                    isActive: local.isActive,
                    iconName: iconName,
                    iconForegroundColor: iconFg,
                    iconBackgroundColor: iconBg
                ))
            } catch {
                logger.warning("Failed to export identity \(local.identityHash): \(error)")
            }
        }
        onProgress(0.1)

        // 2. Export conversations + messages per identity
        for (idx, local) in identities.enumerated() {
            let dbPath = IdentityManager.databasePath(for: local.databaseFilename)
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }

            do {
                let db = try LXMFDatabase(path: dbPath)
                let conversations = try await db.getConversations(limit: 10000, offset: 0)

                for conv in conversations {
                    let peerHashHex = conv.destinationHash.map { String(format: "%02x", $0) }.joined()

                    bundle.conversations.append(ConversationExport(
                        peerHash: peerHashHex,
                        identityHash: local.identityHash,
                        peerName: conv.displayName,
                        lastMessage: conv.lastMessagePreview,
                        lastMessageTimestamp: conv.lastMessageTimestamp.timeIntervalSince1970,
                        unreadCount: conv.unreadCount,
                        isFavorite: conv.isFavorite == 1,
                        iconName: conv.iconName,
                        iconFgColor: conv.iconFgColor,
                        iconBgColor: conv.iconBgColor
                    ))

                    // Export messages for this conversation
                    let records = try await db.getMessageRecords(
                        forConversation: conv.destinationHash, limit: 100000, offset: 0
                    )

                    for record in records {
                        let msgIdHex = record.messageId.map { String(format: "%02x", $0) }.joined()
                        let convHashHex = record.conversationHash.map { String(format: "%02x", $0) }.joined()

                        bundle.messages.append(MessageExport(
                            id: msgIdHex,
                            conversationHash: convHashHex,
                            identityHash: local.identityHash,
                            timestamp: record.timestamp,
                            isIncoming: record.direction == .inbound,
                            state: record.state,
                            method: record.method,
                            packedLxmf: record.packedLxmf.base64EncodedString()
                        ))
                    }
                }
            } catch {
                logger.warning("Failed to export DB for \(local.identityHash): \(error)")
            }

            let identityProgress = Float(idx + 1) / Float(identities.count)
            onProgress(0.1 + identityProgress * 0.5)
        }

        // 3. Export interfaces
        onProgress(0.6)
        let repo = InterfaceRepository()
        let encoder = JSONEncoder()
        for iface in repo.interfaces {
            let configData = (try? encoder.encode(iface.config)) ?? Data()
            let configJson = String(data: configData, encoding: .utf8) ?? "{}"

            bundle.interfaces.append(InterfaceExport(
                name: iface.name,
                type: iface.type.rawValue,
                enabled: iface.enabled,
                configJson: configJson,
                displayOrder: iface.displayOrder
            ))
        }
        onProgress(0.7)

        // 4. Export settings
        let displayName = await settingsRepository.getDisplayName()
        let deliveryMethod = await settingsRepository.getDefaultDeliveryMethod()
        let retryViaRelay = await settingsRepository.getRetryViaRelay()
        let autoSelectRelay = await settingsRepository.getAutoSelectRelay()
        let periodicSync = await settingsRepository.getPeriodicSyncEnabled()
        let syncInterval = await settingsRepository.getSyncInterval()

        var prefs: [PreferenceEntry] = []
        prefs.append(.string("displayName", displayName))
        prefs.append(.string("defaultDeliveryMethod", deliveryMethod))
        prefs.append(.bool("retryViaRelay", retryViaRelay))
        prefs.append(.bool("autoSelectRelay", autoSelectRelay))
        prefs.append(.bool("periodicSyncEnabled", periodicSync))
        prefs.append(.double("syncIntervalSeconds", syncInterval))

        // Auto-announce settings
        let autoAnnounce = UserDefaults.standard.bool(forKey: "auto_announce_enabled")
        let announceInterval = UserDefaults.standard.integer(forKey: "announce_interval_hours")
        prefs.append(.bool("auto_announce_enabled", autoAnnounce))
        if announceInterval > 0 {
            prefs.append(.int("announce_interval_hours", announceInterval))
        }

        // Notification settings
        let notificationsEnabled = UserDefaults.standard.bool(forKey: "notifications_enabled")
        prefs.append(.bool("notifications_enabled", notificationsEnabled))
        let showPreviews = UserDefaults.standard.bool(forKey: "show_message_previews")
        prefs.append(.bool("show_message_previews", showPreviews))
        let playSounds = UserDefaults.standard.bool(forKey: "play_sounds")
        prefs.append(.bool("play_sounds", playSounds))

        // Block unknown senders
        let blockUnknown = UserDefaults.standard.bool(forKey: "block_unknown_senders")
        prefs.append(.bool("block_unknown_senders", blockUnknown))

        bundle.settings = SettingsExport(preferences: prefs)
        onProgress(0.8)

        // 5. Serialize to JSON
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys]
        let jsonData = try jsonEncoder.encode(bundle)
        logger.info("Bundle JSON size: \(jsonData.count) bytes")
        onProgress(0.85)

        // 6. Encrypt
        let encrypted = try MigrationCrypto.encrypt(data: jsonData, password: password)
        logger.info("Encrypted size: \(encrypted.count) bytes")
        onProgress(0.95)

        // 7. Write to temp file
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "columba_backup_\(timestamp).columba"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try encrypted.write(to: tempURL)
        logger.info("Export written to: \(tempURL.path)")
        onProgress(1.0)

        return tempURL
    }
}
#endif
