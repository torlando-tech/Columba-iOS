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
/// Delegate that allows notifications to display while the app is in the foreground.
/// Suppresses banners for messages belonging to the currently visible conversation.
@available(iOS 17.0, macOS 14.0, *)
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // willPresent is called on the main thread (delegate was set on main).
        let threadId = notification.request.content.threadIdentifier
        let activeId = MainActor.assumeIsolated { NotificationService.activeConversationThreadId }
        if !threadId.isEmpty, threadId == activeId {
            // Message is for the conversation the user is currently viewing — skip banner
            completionHandler([])
        } else {
            completionHandler([.banner, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sourceHash = userInfo["sourceHash"] as? String {
            Task { @MainActor in
                NotificationService.pendingConversationHash = sourceHash
            }
        }
        completionHandler()
    }
}

@available(iOS 17.0, macOS 14.0, *)
public final class NotificationService: Sendable {

    // MARK: - Active Conversation Tracking

    /// Thread identifier (hex destination hash) of the conversation currently visible to the user.
    /// Set by MessagingView on appear/disappear. When a notification's threadIdentifier matches,
    /// the foreground banner is suppressed.
    @MainActor static var activeConversationThreadId: String?

    /// Hex destination hash of the conversation to navigate to when a notification is tapped.
    /// Set by NotificationDelegate.didReceive, consumed by ChatsView.
    @MainActor static var pendingConversationHash: String?

    // MARK: - Singleton

    public static let shared = NotificationService()

    /// Delegate for foreground notification display (must be retained).
    nonisolated(unsafe) static let delegate = NotificationDelegate()

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
        static let notifyReceivedMessage = "notify_received_message"
        static let notifyReceivedMessageFavorite = "notify_received_message_favorite"
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
        // Install delegate so notifications display in foreground
        await MainActor.run {
            center.delegate = Self.delegate
        }
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
        database: LXMFDatabase?,
        isFavorite: Bool = false
    ) async {
        // Check user preference
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Keys.notificationsEnabled) else { return }

        // Check per-type toggles
        let notifyAll = defaults.object(forKey: Keys.notifyReceivedMessage) as? Bool ?? true
        let notifyFavoriteOnly = defaults.bool(forKey: Keys.notifyReceivedMessageFavorite)

        // If "favorite only" is on and this sender isn't a favorite, skip
        if notifyFavoriteOnly && !isFavorite { return }
        // If general message notifications are off (and not favorite-filtered), skip
        if !notifyAll && !notifyFavoriteOnly { return }

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
