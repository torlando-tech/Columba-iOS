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

/// Encodes a durable idempotency ledger inside the target message's existing
/// `reactions_json` column. Updating the visible reaction and recording the
/// control-message hash therefore happen in one database UPDATE. If the app is
/// terminated before the separate control-row deletion, replay sees the hash
/// and cannot toggle the reaction a second time.
enum ReactionLedger {
    static let processedKey = "__columba_internal_processed_reaction_hashes_v1"

    struct ApplyResult {
        let state: [String: [String]]
        let didApply: Bool
    }

    static func applying(
        emoji: String,
        sender: String,
        reactionMessageHash: String,
        to current: [String: [String]]
    ) -> ApplyResult {
        var state = current
        var processed = state[processedKey] ?? []
        guard !processed.contains(reactionMessageHash) else {
            return ApplyResult(state: state, didApply: false)
        }

        var senders = state[emoji] ?? []
        if senders.contains(sender) {
            senders.removeAll { $0 == sender }
        } else {
            senders.append(sender)
        }
        if senders.isEmpty {
            state.removeValue(forKey: emoji)
        } else {
            state[emoji] = senders
        }

        processed.append(reactionMessageHash)
        state[processedKey] = processed
        return ApplyResult(state: state, didApply: true)
    }

    static func visibleReactions(_ state: [String: [String]]) -> [String: [String]] {
        state.filter { $0.key != processedKey }
    }
}

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

    /// When true, `handleInbound` skips posting user-facing notifications. Set in
    /// Model B, where the Network Extension already posts the inbound notification
    /// on receipt — the app then only *replays* persisted messages for field
    /// side-channel processing (reactions / telemetry / …), so a second app-side
    /// notification would double-banner.
    public var suppressUserNotifications = false
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
        // Live (non-Model-B) inbound: the in-process LXMRouter delegate fires once
        // per message. Model B has NO live delegate (the NE owns delivery), so
        // `ModelBInboundReplay` calls `handleInbound(_:)` directly over messages the
        // NE persisted to the shared store — identical side-channel processing.
        handleInbound(message)
    }

    /// Run inbound side-channel processing for one ALREADY-PERSISTED message:
    /// reactions (0x40 / legacy 0x10), replies (0x30), peer icon (0x04), cease
    /// (0xFD), telemetry → map pin (0x02), plus the user notification. Does NOT
    /// persist the base message — the LXMRouter (Model A) or the NE (Model B)
    /// already did. In Model B the replay driver sets `suppressUserNotifications`
    /// so this doesn't double-notify (the NE posted the notification on receipt).
    /// - Returns: the `Task` running the side-channel work, so callers that need
    ///   to know when processing has actually COMPLETED (e.g. the Model B replay,
    ///   which must not checkpoint a message as processed until its fields are
    ///   handled) can `await` its `.value`. The live delegate ignores it.
    @discardableResult
    public func handleInbound(_ message: LXMessage) -> Task<Bool, Never> {
        let sourceHashHex = message.sourceHash.prefix(4).map { String(format: "%02x", $0) }.joined()
        let messageHashHex = message.hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        logger.info("Received message from \(sourceHashHex) hash=\(messageHashHex)")

        let sourceHash = message.sourceHash

        // Save to database asynchronously, then notify. Returns whether every
        // REQUIRED field-processing DB write succeeded — the Model B replay
        // checkpoints a message only on `true`, retrying on `false` (a transient
        // write failure) so a reaction / reply / icon update is never silently
        // lost. The live Model A delegate ignores the result.
        return Task {
            var requiredOK = true
            // Reaction — canonical FIELD_REACTION (0x40) = {0x00: targetHashBytes,
            // 0x01: emojiUTF8}; the reacting user is the inbound source hash (not
            // on the wire). Merges into the target message; the empty reaction
            // frame itself is deleted by handleIncomingReaction.
            if let reaction = message.fields?[LxmfFields.FIELD_REACTION] as? [UInt8: Any],
               let toData = reaction[LxmfFields.REACTION_TO] as? Data,
               let emojiData = reaction[LxmfFields.REACTION_CONTENT] as? Data,
               let emoji = String(data: emojiData, encoding: .utf8) {
                let reactionTo = toData.map { String(format: "%02x", $0) }.joined()
                let senderHex = sourceHash.map { String(format: "%02x", $0) }.joined()
                self.logger.info("Reaction \(emoji) (0x40) from \(senderHex.prefix(8)) to \(reactionTo.prefix(8))")
                let ok = await self.handleIncomingReaction(
                    targetMessageHex: reactionTo, emoji: emoji,
                    senderHex: senderHex, reactionMessageHash: message.hash
                )
                NotificationCenter.default.post(
                    name: IncomingMessageHandler.messageReceivedNotification,
                    object: nil, userInfo: ["sourceHash": sourceHash]
                )
                return ok
            }

            // Legacy reaction / reply on FIELD_APP_DATA (0x10) — un-upgraded peers.
            if let appData = message.fields?[LXMessage.FIELD_APP_DATA] as? [String: Any] {
                if let reactionTo = appData["reaction_to"] as? String,
                   let emoji = appData["emoji"] as? String,
                   let sender = appData["sender"] as? String {
                    self.logger.info("Reaction \(emoji) (0x10 legacy) from \(sender.prefix(8)) to \(reactionTo.prefix(8))")
                    let ok = await self.handleIncomingReaction(
                        targetMessageHex: reactionTo, emoji: emoji,
                        senderHex: sender, reactionMessageHash: message.hash
                    )
                    NotificationCenter.default.post(
                        name: IncomingMessageHandler.messageReceivedNotification,
                        object: nil, userInfo: ["sourceHash": sourceHash]
                    )
                    return ok
                }
                if let replyTo = appData["reply_to"] as? String {
                    self.logger.info("Reply (0x10 legacy) to \(replyTo.prefix(8))")
                    do {
                        try await self.messageRepository.updateReplyToId(message.hash, replyToId: replyTo)
                    } catch {
                        self.logger.error("Failed to update reply_to_id (0x10): \(error.localizedDescription)")
                        requiredOK = false
                    }
                }
            }

            // Reply — canonical FIELD_REPLY_HASH (0x30) = raw target-hash bytes.
            if let replyHashData = message.fields?[LxmfFields.FIELD_REPLY_HASH] as? Data {
                let replyTo = replyHashData.map { String(format: "%02x", $0) }.joined()
                self.logger.info("Reply (0x30) to \(replyTo.prefix(8))")
                do {
                    try await self.messageRepository.updateReplyToId(message.hash, replyToId: replyTo)
                } catch {
                    self.logger.error("Failed to update reply_to_id (0x30): \(error.localizedDescription)")
                    requiredOK = false
                }
            }

            // Check block unknown senders setting (needs async DB access).
            // Reads the unified GRDB store via messageRepository (Track A0): the
            // Swift/NE backend writes only that store, so the old Compat
            // `database` would miss Swift/NE-delivered favorites. Same semantics:
            // "known" == an existing conversation with isFavorite != 0.
            if UserDefaults.standard.bool(forKey: "block_unknown_senders") {
                let isKnownContact: Bool
                do {
                    let conversation = try await self.messageRepository.fetchConversation(sourceHash)
                    isKnownContact = conversation != nil && conversation!.isFavorite != 0
                } catch {
                    // Fail open: allow message through if DB check fails
                    isKnownContact = true
                }
                if !isKnownContact {
                    self.logger.info("[LXMF_INBOUND] Blocking message from unknown sender \(sourceHashHex) (block_unknown_senders enabled)")
                    // Stop processing the rest (icon/telemetry/notification), but
                    // return the ACCUMULATED result — a reaction/reply write earlier
                    // in this message may have failed (requiredOK == false), and that
                    // must still be retried rather than masked by the block.
                    return requiredOK
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
                requiredOK = false
            }

            // Look up sender display name from path table (announce data) and update conversation
            if let pathTable = self.pathTable {
                if let entry = await pathTable.lookup(destinationHash: sourceHash),
                   !entry.displayName.isEmpty {
                    try? await self.messageRepository.ensureConversation(sourceHash, displayName: entry.displayName)
                }
            }

            // Check FIELD_CUSTOM_META (0xFD) for the Columba cease flag. The
            // canonical wire form is msgpack `{"cease": true}` (matches Android
            // Columba's TelemeterCodec); the UTF-8-JSON fallback covers older
            // iOS peers that emitted `{"cease": true}` as raw JSON bytes.
            var isCeaseMessage = false
            if let fields = message.fields,
               let metaRaw = fields[LXMessage.FIELD_COLUMBA_META] {
                // Field may arrive as Data (bytes) or String depending on msgpack unpacking
                let metaData: Data?
                if let d = metaRaw as? Data {
                    metaData = d
                } else if let s = metaRaw as? String {
                    metaData = s.data(using: .utf8)
                } else {
                    metaData = nil
                }
                if let metaData {
                    let msgpackCease = ColumbaMetaCodec.unpack(metaData)?.cease == true
                    let jsonCease = String(data: metaData, encoding: .utf8)?.contains("\"cease\"") == true
                    if msgpackCease || jsonCease {
                        isCeaseMessage = true
                        #if os(iOS)
                        await self.locationSharingManager?.handleIncomingCease(from: message.sourceHash)
                        #endif
                        self.logger.debug("Cease signal from \(sourceHashHex)")
                    }
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
            if !isTelemetryOnly && !isCeaseMessage && !isOldMessage && !self.suppressUserNotifications {
                // Skip notification if user is already viewing this conversation
                let sourceThreadId = sourceHash.map { String(format: "%02x", $0) }.joined()
                let activeThread = await MainActor.run { NotificationService.activeConversationThreadId }
                let isViewingConversation = !sourceThreadId.isEmpty && sourceThreadId == activeThread

                if isViewingConversation {
                    // User is viewing this conversation — skip notification
                } else {
                    // Check if sender is a saved/favorite contact
                    // Resolve the sender once from the unified GRDB store (Track A0):
                    // the UI writes favorites + display-names via messageRepository and
                    // the Swift/NE backend persists inbound there, so the old Compat
                    // `database` is stale for both. Passing the resolved name lets
                    // NotificationService use it directly (senderName takes precedence
                    // over its own — now bypassed — Compat lookup).
                    let senderConversation = try? await self.messageRepository.fetchConversation(sourceHash)
                    let senderIsFavorite = (senderConversation?.isFavorite ?? 0) != 0
                    await NotificationService.shared.postMessageNotification(
                        message,
                        senderName: senderConversation?.displayName,
                        database: self.database,
                        isFavorite: senderIsFavorite
                    )
                }
            }

            // Refresh the message-list UIs (chat + conversation) so a newly-saved
            // VISIBLE message shows. Skip telemetry-only and cease messages: they
            // never appear in the list (they're filtered), so a reload is pointless
            // AND harmful — under Model B the replay runs this per inbound including
            // ~60s location beats, and `MessagingViewModel` reloads (resetting to
            // page 1) on each, wiping the older messages a scrolled-up user is
            // viewing. The map pin updates via the @Observable `peerLocations`, not
            // this notification, so telemetry/cease need no refresh. (This also
            // avoids the app re-posting the Darwin ping the Model B replay observes,
            // which would re-trigger a redundant drain.)
            if !isTelemetryOnly && !isCeaseMessage {
                NotificationCenter.default.post(
                    name: IncomingMessageHandler.messageReceivedNotification,
                    object: nil,
                    userInfo: ["sourceHash": sourceHash]
                )
                NotificationObserver.postNewMessage()
            }
            return requiredOK
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

    /// Merge an incoming reaction into the target message's reactions_json and
    /// delete the reaction message. The target update also records the reaction
    /// control hash, making replay idempotent across a crash before deletion.
    /// - Returns: `true` if the reaction was applied, already applied, or invalid;
    ///   `false` only if the durable target update failed transiently.
    @discardableResult
    private func handleIncomingReaction(
        targetMessageHex: String,
        emoji: String,
        senderHex: String,
        reactionMessageHash: Data
    ) async -> Bool {
        // Convert target message hex to Data
        let targetHash = Self.hexToData(targetMessageHex)
        guard let targetHash, targetHash.count == 32 else {
            logger.warning("Invalid reaction target hash: \(targetMessageHex.prefix(16))")
            return true  // malformed — nothing to retry
        }

        // Read-modify-write reactions on the target message
        var mergeOK = true
        do {
            var reactionsDict: [String: [String]] = [:]
            if let json = try await messageRepository.getReactionsJson(targetHash),
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
                reactionsDict = dict
            }

            let reactionHashHex = reactionMessageHash.map {
                String(format: "%02x", $0)
            }.joined()
            let result = ReactionLedger.applying(
                emoji: emoji,
                sender: senderHex,
                reactionMessageHash: reactionHashHex,
                to: reactionsDict
            )

            if result.didApply {
                let jsonData = try JSONSerialization.data(withJSONObject: result.state)
                let jsonStr = String(decoding: jsonData, as: UTF8.self)
                try await messageRepository.updateReactions(targetHash, reactionsJson: jsonStr)
            }
        } catch {
            logger.error("Failed to merge reaction: \(error.localizedDescription)")
            mergeOK = false
        }

        // Best-effort cleanup. A failure is safe: the durable ledger causes the
        // next replay to skip the toggle and retry this deletion only.
        do {
            try await messageRepository.deleteMessage(reactionMessageHash)
        } catch {
            logger.error("Failed to delete reaction message: \(error.localizedDescription)")
        }
        return mergeOK
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
