import Foundation
import UserNotifications

/// Host-local observers; instantiated only in the process owning RNS.
final class NodeHostObservers: @unchecked Sendable {
    private let lock = NSLock()
    func start() { lock.lock(); defer { lock.unlock() }; startInboundBannerObserver(); startBlockSendersObserver() }
    func stop() { lock.lock(); defer { lock.unlock() }; stopInboundBannerObserver(); stopBlockSendersObserver() }
    deinit { stop() }
    // MARK: - Inbound banner (Model B)

    /// Darwin observer token for the NE-published inbound-banner ping. The NE's
    /// Python RNS writes a small `inbound-banner.json` into the shared per-identity
    /// dir + posts `network.columba.inboundBanner`; this observer reads the payload
    /// and posts the user-facing `UNUserNotification` from the NE process. The NE
    /// (not the app) posts it so the banner shows even while the app is suspended
    /// or terminated - the tunnel keeps the NE process alive. Registered on
    /// `startTunnel`, removed on `stopTunnel`.
    private var bannerObserverToken: UnsafeMutableRawPointer?

    /// Register the inbound-banner Darwin observer. Idempotent (guards against a
    /// double `startTunnel`).
    private func startInboundBannerObserver() {
        if bannerObserverToken != nil { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let token = Unmanaged.passUnretained(self).toOpaque()
        let name = "network.columba.inboundBanner"
        CFNotificationCenterAddObserver(
            center,
            token,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let self_ = Unmanaged<NodeHostObservers>.fromOpaque(observer).takeUnretainedValue()
                self_.postInboundBanner()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
        bannerObserverToken = token
        ExtensionDiagLog.log("inbound banner observer registered")
    }

    private func stopInboundBannerObserver() {
        if let token = bannerObserverToken {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                token,
                CFNotificationName("network.columba.inboundBanner" as CFString),
                nil
            )
            bannerObserverToken = nil
        }
    }

    // MARK: - block_unknown_senders live refresh (Issue 3)

    /// Darwin observer token for the app-posted `block_unknown_senders` change
    /// ping. When the user flips the privacy toggle in Settings, the app mirrors
    /// it into the AppGroup suite + posts this name; the observer calls
    /// `rns_bridge.set_block_unknown_senders` on the running node so the inbound
    /// filter refreshes immediately instead of holding the value captured at
    /// `start()` until a restart. Registered on `startTunnel`, removed on
    /// `stopTunnel` (mirrors the inbound-banner observer).
    private var blockSendersObserverToken: UnsafeMutableRawPointer?

    private func startBlockSendersObserver() {
        if blockSendersObserverToken != nil { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let token = Unmanaged.passUnretained(self).toOpaque()
        let name = SharedDefaultsConstants.blockUnknownSendersChangedNotificationName as CFString
        CFNotificationCenterAddObserver(
            center,
            token,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let self_ = Unmanaged<NodeHostObservers>.fromOpaque(observer).takeUnretainedValue()
                self_.refreshBlockUnknownSendersFilter()
            },
            name,
            nil,
            .deliverImmediately
        )
        blockSendersObserverToken = token
    }

    private func stopBlockSendersObserver() {
        if let token = blockSendersObserverToken {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                token,
                CFNotificationName(SharedDefaultsConstants.blockUnknownSendersChangedNotificationName as CFString),
                nil
            )
            blockSendersObserverToken = nil
        }
    }

    /// Read the freshly-mirrored value from the shared suite and push it to the
    /// running node. No-op when Python isn't running (the value is still picked
    /// up at the next node `start`, which reads it from the same suite).
    private func refreshBlockUnknownSendersFilter() {
        let value = UserDefaults(suiteName: "group.network.columba.Columba")?
            .bool(forKey: "block_unknown_senders") ?? false
        PythonNodeEngine.shared.invoke(
            "set_block_unknown_senders",
            kwargs: ["block_unknown_senders": value]
        )
        ExtensionDiagLog.log("[NE-PY-RNS] block_unknown_senders refreshed to \(value)")
    }

    /// Read the banner payload the NE's Python wrote, and post a local
    /// `UNUserNotification`. Mirrors the app's `NotificationService` posture: honor
    /// the host's authorization (the app owns the prompt; the NE never requests
    /// auth), show a brief preview, thread by sender. Best-effort - a failure
    /// (e.g. not authorized) just logs; the message is still persisted to the
    /// shared store + unread, so it surfaces on next open.
    private func postInboundBanner() {
        // Resolve the shared per-identity dir (where the Python wrote the payload).
        let configDir = PythonNodeEngine.sharedConfigDir()
        let payloadPath = (configDir as NSString).appendingPathComponent("inbound-banner.json")
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)) else {
            ExtensionDiagLog.log("inbound banner: no payload")
            return
        }
        struct Banner: Decodable {
            let senderPrefix: String
            let displayName: String?
            let preview: String
            let threadId: String
        }
        let banner = (try? JSONDecoder().decode(Banner.self, from: raw))
        let center = UNUserNotificationCenter.current()
        Task {
            // Honor the host's authorization only (the app owns the prompt; we never
            // request it from the NE).
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else {
                ExtensionDiagLog.log("inbound banner: not authorized - skipping")
                return
            }
            let title = banner?.displayName ?? "Peer \(banner?.senderPrefix ?? "0000")"
            let previewText = banner?.preview ?? ""
            let body = previewText.isEmpty ? "New message" : previewText
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.threadIdentifier = banner?.threadId ?? UUID().uuidString
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "columba.inbound." + UUID().uuidString,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                ExtensionDiagLog.log("inbound banner posted from=\(banner?.senderPrefix ?? "??")")
            } catch {
                ExtensionDiagLog.log("inbound banner failed: \(error.localizedDescription)")
            }
        }
    }

}
