//
//  NotificationObserver.swift
//  ColumbaApp
//
//  Darwin notification listener for IPC from the Network Extension.
//  Uses CFNotificationCenter for cross-process communication, bridged to
//  in-process NotificationCenter posts the UI observes.
//

import Foundation
import RNSAPI

/// Observer for Darwin notifications from the Network Extension.
///
/// Under Model B the NE owns delivery + the BLE/interface state and PUSHES these
/// signals on change; the app reacts (fetch once) instead of polling. Two channels:
///  - `newMessageNotification` → inbound LXMF / delivery proof landed.
///  - `networkStateChangedNotification` → BLE/interface state changed (peer
///    connect/disconnect, interface up/down) — the cue for status/connection UIs.
///
/// CFNotificationCenter (Darwin notifications) works across process boundaries,
/// unlike NSNotificationCenter; each is bridged to an in-process post for the UI.
public final class NotificationObserver: @unchecked Sendable {
    // MARK: - Darwin notification names (must match the NE's posters)

    /// Posted by the NE when a new inbound LXMF message / delivery proof lands.
    public static let newMessageNotification = "network.columba.newMessage" as CFString

    /// Posted by the NE when network/BLE state changes (peer connect/disconnect,
    /// interface up/down).
    public static let networkStateChangedNotification = "network.columba.networkStateChanged" as CFString

    /// In-process notification re-posted from `networkStateChangedNotification`,
    /// observed by the status / interface / BLE-connection view-models so they
    /// refresh once on change instead of polling the NE on a timer.
    public static let networkStateChangedInApp = Notification.Name("network.columba.networkStateChanged.inapp")

    /// Posted by the NE (Model B) as a propagation sync advances. The snapshot
    /// (`PropagationSyncStateSnapshot`) rides the App-Group, since Darwin carries no
    /// payload.
    public static let propagationSyncStateChangedNotification =
        SharedDefaultsConstants.propagationSyncStateChangedNotificationName as CFString

    /// In-process re-post of `propagationSyncStateChangedNotification`, observed by
    /// `PropagationNodeManager` to drive the in-app sync sheet.
    public static let propagationSyncStateChangedInApp =
        Notification.Name("network.columba.propagationSyncStateChanged.inapp")

    // MARK: - Properties

    /// Callback invoked when a new-message notification is received.
    private var callback: (@Sendable () -> Void)?

    // MARK: - Initialization

    /// Create observer and register for Darwin notifications.
    public init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        // New-message channel → callback + bridge to messageReceivedNotification.
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let self_ = Unmanaged<NotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                self_.callback?()
                // Bridge the cross-process Darwin signal to the in-process
                // `messageReceivedNotification` the rest of the UI observes (the open
                // thread's `MessagingViewModel`, message views). Under Model B the NE
                // delivers inbound LXMF + receives delivery proofs and posts ONLY this
                // Darwin notification — the app-local `IncomingMessageHandler` never
                // fires — so without this re-post an open conversation never reloads
                // inbound messages or advances the sent-message delivery checkmarks.
                // `loadMessages` re-reads both, so no per-message userInfo is needed.
                NotificationCenter.default.post(
                    name: IncomingMessageHandler.messageReceivedNotification,
                    object: nil
                )
            },
            Self.newMessageNotification,
            nil,
            .deliverImmediately
        )

        // Network/BLE-state channel → bridge to `networkStateChangedInApp`. Replaces
        // the always-on 1-2s polls the status / interface / BLE-connection view-models
        // used to hammer the NE with (a ~10/s app<->NE IPC flood); they now fetch once
        // in response. No `self` needed — just forward the signal in-process.
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                NotificationCenter.default.post(
                    name: NotificationObserver.networkStateChangedInApp,
                    object: nil
                )
            },
            Self.networkStateChangedNotification,
            nil,
            .deliverImmediately
        )

        // Propagation sync-state channel (Model B) → bridge to
        // `propagationSyncStateChangedInApp`. `PropagationNodeManager` reads the
        // App-Group snapshot in response and updates its `syncState` for the sheet.
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                NotificationCenter.default.post(
                    name: NotificationObserver.propagationSyncStateChangedInApp,
                    object: nil
                )
            },
            Self.propagationSyncStateChangedNotification,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center, observer, CFNotificationName(Self.newMessageNotification), nil
        )
        CFNotificationCenterRemoveObserver(
            center, observer, CFNotificationName(Self.networkStateChangedNotification), nil
        )
        CFNotificationCenterRemoveObserver(
            center, observer, CFNotificationName(Self.propagationSyncStateChangedNotification), nil
        )
    }

    // MARK: - Public Methods

    /// Register callback for new-message notifications.
    ///
    /// The callback is invoked on the thread that posts the notification, which may
    /// not be the main thread. Hop to @MainActor / DispatchQueue.main for UI.
    public func onNewMessage(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    // MARK: - Static posters (NE side)

    /// Post the new-message notification. Called by the NE when a new LXMF message is
    /// received and stored; the main app observes this to refresh its message list.
    public static func postNewMessage() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.newMessageNotification),
            nil, nil, true
        )
    }

    /// Post the network/BLE-state-changed notification. Called by the NE when a BLE
    /// peer connects/disconnects or an interface changes state; status/connection UIs
    /// observe `networkStateChangedInApp` and refresh once.
    public static func postNetworkStateChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.networkStateChangedNotification),
            nil, nil, true
        )
    }
}
