//
//  NotificationService.swift
//  ColumbaApp
//
//  Manages iOS local notifications for incoming LXMF messages.
//  Handles permission requests and respects user notification preferences.
//

import Foundation
import RNSAPI
import UserNotifications

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

    static func shouldPostMessageNotification(
        isFavorite: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: Keys.notificationsEnabled) else { return false }
        let notifyAll = defaults.object(forKey: Keys.notifyReceivedMessage) as? Bool ?? true
        let notifyFavoriteOnly = defaults.bool(forKey: Keys.notifyReceivedMessageFavorite)
        if notifyFavoriteOnly && !isFavorite { return false }
        if !notifyAll && !notifyFavoriteOnly { return false }
        return true
    }

    /// Convert the canonical unread total into a badge value. A failed database
    /// read yields no badge mutation rather than reviving stale Notification
    /// Center history.
    static func badgeValue(totalUnreadCount: Int?) -> NSNumber? {
        guard let totalUnreadCount else { return nil }
        return NSNumber(value: max(0, totalUnreadCount))
    }

    /// Post a local notification for an incoming LXMF message.
    ///
    /// Respects user preferences for notifications, previews, and sounds.
    /// Only posts if the app is not in the foreground.
    ///
    /// - Parameters:
    ///   - message: The incoming LXMessage
    ///   - senderName: Display name of the sender (nil = show hash)
    ///   - database: Database for looking up conversation display name
    ///   - totalUnreadCount: Canonical durable unread total for the icon badge
    @discardableResult
    public func postMessageNotification(
        _ message: LXMessage,
        senderName: String?,
        database: LXMFDatabase?,
        isFavorite: Bool = false,
        totalUnreadCount: Int?
    ) async -> Bool {
        let defaults = UserDefaults.standard
        guard Self.shouldPostMessageNotification(isFavorite: isFavorite, defaults: defaults) else {
            DiagLog.log("[NOTIFICATION] skipped by message notification preferences")
            return false
        }

        // Check system permission
        guard await isAuthorized() else {
            DiagLog.log("[NOTIFICATION] skipped: system authorization unavailable")
            return false
        }

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

        // Badge: use canonical unread state, not retained Notification Center
        // history. The latter survives clearBadge() and caused values such as 100.
        content.badge = Self.badgeValue(totalUnreadCount: totalUnreadCount)

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
            DiagLog.log(
                "[NOTIFICATION] submitted message request badge=\(totalUnreadCount.map(String.init) ?? "unchanged")"
            )
            return true
        } catch {
            DiagLog.log("[NOTIFICATION] submission failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Badge Management

    /// Reconcile the icon badge with canonical durable unread state. Notification
    /// Center history is presentation state and is never used as an unread counter.
    public func synchronizeBadgeWithDurableUnreadCount(_ totalUnreadCount: Int) async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(max(0, totalUnreadCount))
            DiagLog.log("[NOTIFICATION] badge synchronized unread=\(max(0, totalUnreadCount))")
        } catch {
            DiagLog.log("[NOTIFICATION] badge synchronization failed: \(error.localizedDescription)")
        }
    }
}
