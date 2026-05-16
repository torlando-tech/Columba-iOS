//
//  IncomingMessageHandler.swift
//  ColumbaApp
//
//  Handler for incoming LXMF messages from LXMRouter.
//  Saves received messages to database and triggers UI refresh notifications.
//

import Foundation
import RNSAPI
import UserNotifications
import os.log

/// Handler for incoming LXMF messages.
///
/// Conforms to `LXMRouterDelegate` to receive callbacks when messages arrive.
/// Saves incoming messages to the database via `MessageRepository` and posts
/// Darwin notifications to trigger UI refresh.
///
/// Must be `@MainActor` to satisfy `LXMRouterDelegate` protocol requirements
/// and ensure thread-safe UI operations.
@MainActor
public final class IncomingMessageHandler: LXMRouterDelegate {
    // MARK: - Constants

    /// In-process notification posted when a new message is saved to the database.
    /// The `userInfo` contains "sourceHash" (Data) for the conversation that changed.
    public static let messageReceivedNotification = Notification.Name("com.columba.messageReceived")

    // MARK: - Properties

    /// Repository for persisting messages to database.
    private let messageRepository: MessageRepository

    /// Database for notification sender name lookups.
    private let database: LXMFDatabase?

    /// Path table for looking up sender display names from announces.
    public var pathTable: PathTable?

    #if os(iOS)
    /// Location sharing manager for incoming telemetry extraction.
    public var locationSharingManager: LocationSharingManager?
    #endif

    /// Timestamp when this handler was created.
    /// Messages older than this are from propagation sync backfill, not new arrivals.
    private let createdAt = Date()

    /// Logger for debugging message receipt.
    private let logger = Logger(subsystem: "network.columba.Columba", category: "IncomingMessageHandler")

    // MARK: - Initialization

    /// Create handler with message repository.
    ///
    /// - Parameters:
    ///   - messageRepository: Repository for saving messages to database
    ///   - database: Database for sender name lookups in notifications
    ///   - locationSharingManager: Optional manager for extracting incoming telemetry
    #if os(iOS)
    public init(messageRepository: MessageRepository, database: LXMFDatabase? = nil, locationSharingManager: LocationSharingManager? = nil) {
        self.messageRepository = messageRepository
        self.database = database
        self.locationSharingManager = locationSharingManager
    }
    #else
    public init(messageRepository: MessageRepository, database: LXMFDatabase? = nil) {
        self.messageRepository = messageRepository
        self.database = database
    }
    #endif

    // MARK: - LXMRouterDelegate

    /// Called when a message is received and validated.
    ///
    /// Saves the message to the database and posts a notification
    /// to trigger UI refresh.
    ///
    /// - Parameters:
    ///   - router: The router that received the message
    ///   - message: The validated incoming message
    public func router(_ router: LXMRouter, didReceiveMessage message: LXMessage) {
        let sourceHashHex = message.sourceHash.prefix(4).map { String(format: "%02x", $0) }.joined()
        let messageHashHex = message.hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        logger.info("Received message from \(sourceHashHex) hash=\(messageHashHex)")

        let sourceHash = message.sourceHash

        // Save to database asynchronously, then notify
        Task {
            // Check for FIELD_APP_DATA (0x10) — reactions and replies
            if let appData = message.fields?[LXMessage.FIELD_APP_DATA] as? [String: Any] {
                // Handle reaction messages: merge into target, delete reaction message from DB
                if let reactionTo = appData["reaction_to"] as? String,
                   let emoji = appData["emoji"] as? String,
                   let sender = appData["sender"] as? String {
                    self.logger.info("Reaction \(emoji) from \(sender.prefix(8)) to \(reactionTo.prefix(8))")
                    await self.handleIncomingReaction(
                        targetMessageHex: reactionTo,
                        emoji: emoji,
                        senderHex: sender,
                        reactionMessageHash: message.hash
                    )
                    // Post notification so open conversation reloads with updated reactions
                    NotificationCenter.default.post(
                        name: IncomingMessageHandler.messageReceivedNotification,
                        object: nil,
                        userInfo: ["sourceHash": sourceHash]
                    )
                    return  // Skip normal message processing
                }

                // Handle reply messages: update reply_to_id column
                if let replyTo = appData["reply_to"] as? String {
                    self.logger.info("Reply to \(replyTo.prefix(8))")
                    do {
                        try await self.messageRepository.updateReplyToId(message.hash, replyToId: replyTo)
                    } catch {
                        self.logger.error("Failed to update reply_to_id: \(error.localizedDescription)")
                    }
                }
            }

            // Check block unknown senders setting (needs async DB access)
            if UserDefaults.standard.bool(forKey: "block_unknown_senders"),
               let db = self.database {
                let isKnownContact: Bool
                do {
                    let conversation = try await db.getConversation(hash: sourceHash)
                    isKnownContact = conversation != nil && conversation!.isFavorite != 0
                } catch {
                    // Fail open: allow message through if DB check fails
                    isKnownContact = true
                }
                if !isKnownContact {
                    self.logger.info("[LXMF_INBOUND] Blocking message from unknown sender \(sourceHashHex) (block_unknown_senders enabled)")
                    return
                }
            }

            // Note: message is already saved to DB by LXMRouter before calling delegate.
            // We only need to handle extra work the router doesn't do.
            do {
                // Extract icon appearance from LXMF Field 4
                if let fields = message.fields,
                   let iconValue = fields[IconAppearance.fieldKey],
                   let icon = IconAppearance.fromLXMFFieldValue(iconValue) {
                    try await self.messageRepository.updatePeerIcon(message.sourceHash, icon: icon)
                    self.logger.info("Saved peer icon: \(icon.iconName) for \(sourceHashHex)")
                }
            } catch {
                self.logger.error("[LXMF_INBOUND] Failed to update peer icon for \(messageHashHex): \(error.localizedDescription)")
            }

            // Look up sender display name from path table (announce data) and update conversation
            if let pathTable = self.pathTable {
                if let entry = await pathTable.lookup(destinationHash: sourceHash),
                   !entry.displayName.isEmpty {
                    try? await self.messageRepository.ensureConversation(sourceHash, displayName: entry.displayName)
                }
            }

            // Check for FIELD_COLUMBA_META (0x70) cease signal (Android Columba format)
            var isCeaseMessage = false
            if let fields = message.fields,
               let metaRaw = fields[LXMessage.FIELD_COLUMBA_META] {
                // Field may arrive as Data (bytes) or String depending on msgpack unpacking
                let metaStr: String?
                if let d = metaRaw as? Data {
                    metaStr = String(data: d, encoding: .utf8)
                } else if let s = metaRaw as? String {
                    metaStr = s
                } else {
                    metaStr = nil
                }
                if let metaStr, metaStr.contains("\"cease\"") {
                    isCeaseMessage = true
                    #if os(iOS)
                    await self.locationSharingManager?.handleIncomingCease(from: message.sourceHash)
                    #endif
                    self.logger.debug("Cease signal from \(sourceHashHex)")
                }
            }

            // Extract telemetry from LXMF Field 2 (FIELD_TELEMETRY)
            if let fields = message.fields {
                // Extract icon appearance for map marker (may already be saved to DB above)
                var peerIcon: IconAppearance? = nil
                if let iconValue = fields[IconAppearance.fieldKey] {
                    peerIcon = IconAppearance.fromLXMFFieldValue(iconValue)
                }
                // Fall back to DB-stored icon if not in this message
                if peerIcon == nil {
                    peerIcon = try? await self.messageRepository.getPeerIcon(message.sourceHash)
                }

                if let telemetryData = fields[LXMessage.FIELD_TELEMETRY] as? Data,
                   let packet = TelemetryPacket.decode(from: telemetryData) {
                    #if os(iOS)
                    self.locationSharingManager?.handleIncomingTelemetry(
                        from: message.sourceHash,
                        packet: packet,
                        displayName: nil,
                        iconAppearance: peerIcon
                    )
                    #endif
                }
            }

            // Post local push notification (respects user preferences).
            // Skip telemetry-only and cease messages to avoid notification spam.
            // Skip messages older than handler creation — these are propagation sync
            // backfill, not genuinely new arrivals.
            let isTelemetryOnly = message.content.isEmpty
                && message.fields?[LXMessage.FIELD_TELEMETRY] != nil
            let isOldMessage = message.timestamp < self.createdAt.timeIntervalSince1970
            if !isTelemetryOnly && !isCeaseMessage && !isOldMessage {
                // Skip notification if user is already viewing this conversation
                let sourceThreadId = sourceHash.map { String(format: "%02x", $0) }.joined()
                let activeThread = await MainActor.run { NotificationService.activeConversationThreadId }
                let isViewingConversation = !sourceThreadId.isEmpty && sourceThreadId == activeThread

                if isViewingConversation {
                    // User is viewing this conversation — skip notification
                } else {
                    // Check if sender is a saved/favorite contact
                    let senderIsFavorite: Bool
                    if let db = self.database {
                        senderIsFavorite = ((try? await db.getConversation(hash: sourceHash))?.isFavorite ?? 0) != 0
                    } else {
                        senderIsFavorite = false
                    }
                    await NotificationService.shared.postMessageNotification(
                        message,
                        senderName: nil,
                        database: self.database,
                        isFavorite: senderIsFavorite
                    )
                }
            }

            // Post notification so views reload with saved data
            NotificationCenter.default.post(
                name: IncomingMessageHandler.messageReceivedNotification,
                object: nil,
                userInfo: ["sourceHash": sourceHash]
            )
            NotificationObserver.postNewMessage()
        }
    }

    /// Called when a delivery proof is received for a sent message.
    ///
    /// Updates UI to show double checkmark (delivered status).
    ///
    /// - Parameters:
    ///   - router: The router managing the message
    ///   - messageHash: The hash of the delivered message
    public func router(_ router: LXMRouter, didConfirmDelivery messageHash: Data) {
        let hashHex = messageHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.info("Delivery confirmed for message \(hashHex)")

        // Post in-process notification to refresh open conversation view.
        // No sourceHash filter — all open MessagingViewModels will reload
        // and pick up the .delivered state from DB (double checkmark).
        NotificationCenter.default.post(
            name: IncomingMessageHandler.messageReceivedNotification,
            object: nil
        )
        NotificationObserver.postNewMessage()
    }

    /// Called when an outbound message state changes.
    ///
    /// Logs the state change for debugging. The database update is handled
    /// by the router itself.
    ///
    /// - Parameters:
    ///   - router: The router managing the message
    ///   - message: The message with updated state
    public func router(_ router: LXMRouter, didUpdateMessage message: LXMessage) {
        let messageHashHex = message.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.info("Message \(messageHashHex)... state updated to \(String(describing: message.state))")

        // Post notification to refresh UI with new state
        NotificationObserver.postNewMessage()
    }

    /// Called when an outbound message delivery fails.
    ///
    /// Logs the failure for debugging. The database update is handled
    /// by the router itself.
    ///
    /// - Parameters:
    ///   - router: The router managing the message
    ///   - message: The failed message
    ///   - reason: The error causing failure
    public func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError) {
        let messageHashHex = message.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        logger.error("Message \(messageHashHex)... delivery failed: \(String(describing: reason))")

        // Post notification to refresh UI with failed state
        NotificationObserver.postNewMessage()
    }

    // MARK: - Reaction Handling

    /// Merge an incoming reaction into the target message's reactions_json and delete the reaction message.
    private func handleIncomingReaction(
        targetMessageHex: String,
        emoji: String,
        senderHex: String,
        reactionMessageHash: Data
    ) async {
        // Convert target message hex to Data
        let targetHash = Self.hexToData(targetMessageHex)
        guard let targetHash, targetHash.count == 32 else {
            logger.warning("Invalid reaction target hash: \(targetMessageHex.prefix(16))")
            return
        }

        // Read-modify-write reactions on the target message
        do {
            var reactionsDict: [String: [String]] = [:]
            if let json = try await messageRepository.getReactionsJson(targetHash),
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
                reactionsDict = dict
            }

            // Toggle: if sender already reacted with this emoji, remove; otherwise add
            var senders = reactionsDict[emoji] ?? []
            if senders.contains(senderHex) {
                senders.removeAll { $0 == senderHex }
            } else {
                senders.append(senderHex)
            }

            if senders.isEmpty {
                reactionsDict.removeValue(forKey: emoji)
            } else {
                reactionsDict[emoji] = senders
            }

            // Serialize and save
            if reactionsDict.isEmpty {
                try await messageRepository.updateReactions(targetHash, reactionsJson: "")
            } else if let jsonData = try? JSONSerialization.data(withJSONObject: reactionsDict),
                      let jsonStr = String(data: jsonData, encoding: .utf8) {
                try await messageRepository.updateReactions(targetHash, reactionsJson: jsonStr)
            }
        } catch {
            logger.error("Failed to merge reaction: \(error.localizedDescription)")
        }

        // Delete the reaction message from DB (it's a control message, not a visible message)
        do {
            try await messageRepository.deleteMessage(reactionMessageHash)
        } catch {
            logger.error("Failed to delete reaction message: \(error.localizedDescription)")
        }
    }

    /// Convert hex string to Data.
    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var chars = hex[hex.startIndex...]
        while chars.count >= 2 {
            let end = chars.index(chars.startIndex, offsetBy: 2)
            guard let byte = UInt8(chars[chars.startIndex..<end], radix: 16) else { return nil }
            data.append(byte)
            chars = chars[end...]
        }
        return data
    }
}
