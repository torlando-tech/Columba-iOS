//
//  IncomingMessageHandler.swift
//  ColumbaApp
//
//  Handler for incoming LXMF messages from LXMRouter.
//  Saves received messages to database and triggers UI refresh notifications.
//

import Foundation
import LXMFSwift
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

    /// Logger for debugging message receipt.
    private let logger = Logger(subsystem: "com.columba.app", category: "IncomingMessageHandler")

    // MARK: - Initialization

    /// Create handler with message repository.
    ///
    /// - Parameter messageRepository: Repository for saving messages to database
    public init(messageRepository: MessageRepository) {
        self.messageRepository = messageRepository
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
        // Log receipt for debugging
        let sourceHashHex = message.sourceHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let messageHashHex = message.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let contentPreview = String(data: message.content.prefix(50), encoding: .utf8) ?? "<binary>"

        print("[LXMF_INBOUND] *** IncomingMessageHandler.router(didReceiveMessage:) called! ***")
        print("[LXMF_INBOUND] sourceHash=\(sourceHashHex), msgHash=\(messageHashHex)")
        print("[LXMF_INBOUND] content preview: \(contentPreview)")
        logger.info("Received message from \(sourceHashHex)... hash=\(messageHashHex)... content=\(contentPreview)")

        // Save to database asynchronously, then notify
        let sourceHash = message.sourceHash
        Task {
            do {
                try await messageRepository.saveMessage(message)
                logger.debug("Message \(messageHashHex)... saved to database")

                // Post in-process notification so open chat views refresh immediately
                NotificationCenter.default.post(
                    name: IncomingMessageHandler.messageReceivedNotification,
                    object: nil,
                    userInfo: ["sourceHash": sourceHash]
                )
            } catch {
                logger.error("Failed to save message \(messageHashHex)...: \(error.localizedDescription)")
            }
        }

        // Post Darwin notification to trigger UI refresh
        // This works across process boundaries (e.g., from Network Extension to main app)
        NotificationObserver.postNewMessage()
        logger.debug("Posted new message notification")
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
