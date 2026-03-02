//
//  IncomingMessageHandler.swift
//  ColumbaApp
//
//  Handler for incoming LXMF messages from LXMRouter.
//  Saves received messages to database and triggers UI refresh notifications.
//

import Foundation
import LXMFSwift
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

    /// Location sharing manager for incoming telemetry extraction.
    public var locationSharingManager: LocationSharingManager?

    /// Timestamp when this handler was created.
    /// Messages older than this are from propagation sync backfill, not new arrivals.
    private let createdAt = Date()

    /// Logger for debugging message receipt.
    private let logger = Logger(subsystem: "com.columba.app", category: "IncomingMessageHandler")

    // MARK: - Initialization

    /// Create handler with message repository.
    ///
    /// - Parameters:
    ///   - messageRepository: Repository for saving messages to database
    ///   - database: Database for sender name lookups in notifications
    ///   - locationSharingManager: Optional manager for extracting incoming telemetry
    public init(messageRepository: MessageRepository, database: LXMFDatabase? = nil, locationSharingManager: LocationSharingManager? = nil) {
        self.messageRepository = messageRepository
        self.database = database
        self.locationSharingManager = locationSharingManager
    }

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
                    self.locationSharingManager?.handleIncomingCease(from: message.sourceHash)
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
                    self.locationSharingManager?.handleIncomingTelemetry(
                        from: message.sourceHash,
                        packet: packet,
                        displayName: nil,
                        iconAppearance: peerIcon
                    )
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
}
