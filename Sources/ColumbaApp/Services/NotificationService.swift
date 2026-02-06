//
//  NotificationService.swift
//  ColumbaApp
//
//  Manages iOS local notifications for incoming LXMF messages.
//  Handles permission requests and respects user notification preferences.
//

import Foundation
import UserNotifications
import LXMFSwift

/// Manages local push notifications for incoming messages.
///
/// Reads notification preferences from UserDefaults (same keys as SettingsViewModel)
/// and posts local notifications via UNUserNotificationCenter when messages arrive.
@available(iOS 17.0, macOS 14.0, *)
public final class NotificationService: Sendable {

    // MARK: - Singleton

    public static let shared = NotificationService()

    // MARK: - Constants

    /// Notification category for message notifications (supports inline reply).
    static let messageCategoryId = "LXMF_MESSAGE"

    /// Action ID for inline reply.
    static let replyActionId = "REPLY_ACTION"

    // MARK: - UserDefaults Keys (matches SettingsViewModel)

    private enum Keys {
        static let notificationsEnabled = "notifications_enabled"
        static let showMessagePreviews = "show_message_previews"
        static let playSounds = "play_sounds"
    }

    // MARK: - Init

    private init() {}

    // MARK: - Permission

    /// Request notification permission from the user.
    ///
    /// Should be called on first launch or when the user enables the notification toggle.
    /// Returns the authorization status after the request.
    @discardableResult
    public func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                await registerCategories()
            }
            return granted
        } catch {
            return false
        }
    }

    /// Check current authorization status.
    public func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    // MARK: - Categories

    /// Register notification categories (enables inline reply action).
    private func registerCategories() async {
        let replyAction = UNTextInputNotificationAction(
            identifier: Self.replyActionId,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )

        let messageCategory = UNNotificationCategory(
            identifier: Self.messageCategoryId,
            actions: [replyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([messageCategory])
    }

    // MARK: - Post Notification

    /// Post a local notification for an incoming LXMF message.
    ///
    /// Respects user preferences for notifications, previews, and sounds.
    /// Only posts if the app is not in the foreground.
    ///
    /// - Parameters:
    ///   - message: The incoming LXMessage
    ///   - senderName: Display name of the sender (nil = show hash)
    ///   - database: Database for looking up conversation display name
    public func postMessageNotification(
        _ message: LXMessage,
        senderName: String?,
        database: LXMFDatabase?
    ) async {
        // Check user preference
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Keys.notificationsEnabled) else { return }

        // Check system permission
        guard await isAuthorized() else { return }

        // Build sender display
        let senderDisplay: String
        if let name = senderName, !name.isEmpty {
            senderDisplay = name
        } else {
            // Try to look up from conversation record
            var dbName: String?
            if let db = database {
                dbName = try? await db.getConversation(hash: message.sourceHash)?.displayName
            }
            if let name = dbName, !name.isEmpty {
                senderDisplay = name
            } else {
                // Fall back to truncated hash
                let hex = message.sourceHash.prefix(4).map { String(format: "%02x", $0) }.joined()
                senderDisplay = "[\(hex)...]"
            }
        }

        let content = UNMutableNotificationContent()
        content.title = senderDisplay
        content.categoryIdentifier = Self.messageCategoryId

        // Thread identifier groups notifications by conversation
        let threadId = message.sourceHash.map { String(format: "%02x", $0) }.joined()
        content.threadIdentifier = threadId

        // Body: show preview or generic text based on user preference
        let showPreviews = defaults.bool(forKey: Keys.showMessagePreviews)
        if showPreviews {
            let bodyText = String(data: message.content, encoding: .utf8) ?? "New message"
            content.body = bodyText
        } else {
            content.body = "New message"
        }

        // Sound
        let playSound = defaults.bool(forKey: Keys.playSounds)
        content.sound = playSound ? .default : nil

        // Badge: increment
        let currentBadge = await UNUserNotificationCenter.current().deliveredNotifications().count
        content.badge = NSNumber(value: currentBadge + 1)

        // Store source hash in userInfo for navigation on tap
        content.userInfo = [
            "sourceHash": message.sourceHash.map { String(format: "%02x", $0) }.joined()
        ]

        // Create request with unique ID (message hash)
        let requestId = message.hash.map { String(format: "%02x", $0) }.joined()
        let request = UNNotificationRequest(
            identifier: requestId,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Silently fail — notification is non-critical
        }
    }

    // MARK: - Badge Management

    /// Clear the badge count (call when app becomes active).
    public func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}
