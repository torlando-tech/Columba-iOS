//
//  NotificationObserver.swift
//  ColumbaApp
//
//  Darwin notification listener for IPC from Network Extension.
//  Uses CFNotificationCenter for cross-process communication.
//

import Foundation
import RNSAPI

/// Observer for Darwin notifications from Network Extension.
///
/// Provides real-time notification when new messages arrive, allowing
/// the app to refresh UI immediately when the Network Extension receives
/// messages while backgrounded.
///
/// Uses CFNotificationCenter (Darwin notifications) which work across
/// process boundaries, unlike NSNotificationCenter.
public final class NotificationObserver: @unchecked Sendable {
    // MARK: - Constants

    /// Darwin notification name posted when new LXMF message arrives.
    public static let newMessageNotification = "network.columba.newMessage" as CFString

    // MARK: - Properties

    /// Callback invoked when new message notification is received.
    private var callback: (@Sendable () -> Void)?

    // MARK: - Initialization

    /// Create observer and register for Darwin notifications.
    public init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let self_ = Unmanaged<NotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                self_.callback?()
            },
            Self.newMessageNotification,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName(Self.newMessageNotification),
            nil
        )
    }

    // MARK: - Public Methods

    /// Register callback for new message notifications.
    ///
    /// The callback is invoked on the thread that posts the notification,
    /// which may not be the main thread. Use @MainActor or DispatchQueue.main
    /// if you need to update UI.
    ///
    /// - Parameter callback: Closure called when notification is received
    public func onNewMessage(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    // MARK: - Static Methods

    /// Post new message notification.
    ///
    /// Called by Network Extension when new LXMF message is received and stored.
    /// The main app observes this to refresh its message list.
    public static func postNewMessage() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(Self.newMessageNotification),
            nil,
            nil,
            true
        )
    }
}
