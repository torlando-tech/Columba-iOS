//
//  NEReticulumNode.swift
//  ColumbaNetworkExtension
//
//  Track A5a — the NE-side RNS + LXMF node core (Model B keystone).
//
//  A minimal Reticulum + LXMF node that runs INSIDE the Network Extension so the
//  NE can complete LXMF delivery itself (persist + notify) while the host app is
//  suspended, instead of acting as a dumb TCP pipe back to the app. This is the
//  Model B counterpart to the app-side `SwiftRNSBackend`: the node setup
//  (transport + router + lxmf.delivery destination + App-Group bridge interface)
//  mirrors `SwiftRNSBackend.start()` directly on reticulum-swift / LXMF-swift.
//
//  SCOPE (A5a only):
//    • node setup (transport / router / delivery destination),
//    • shared-identity load from the App's keychain group,
//    • App-Group GRDB path computation (LXMF-swift owns the store),
//    • AppGroupBridgeInterface registration on the transport,
//    • inbound delivery → (LXMF-swift persists) → local notification + DB-changed
//      Darwin notification so the app refreshes.
//  Explicitly NOT here: the live TCP/relay path (Track C3 — see TODO(C3) below),
//  the app-side ProxyRnsBackend IPC (A5b), the durable outbox (A5c).
//
//  GATING: this node MUST NOT auto-start in `startTunnel` yet — doing so would
//  run-conflict with the live PoC dumb-pipe (`PacketTunnelProvider`'s
//  NWConnection path, which is still the shipping behaviour). It is exposed as a
//  constructible / startable type, but its activation is guarded behind
//  `NEReticulumNode.modelBNodeEnabled`, which is `false`. Track C3 flips that flag
//  and wires `start()` live (replacing the dumb-pipe). For now the goal is solely
//  that this COMPILES + LINKS via the `ColumbaNetworkExtension` scheme.
//
//  ── COLLISION RULE (HARD — bit us in A0) ─────────────────────────────────────
//  This file imports ONLY: Foundation, UserNotifications, ReticulumSwift,
//  LXMFSwift. It MUST NOT import RNSAPI or RNSBackendSwift — RNSAPI's Compat layer
//  re-declares Identity / Destination / Link / ReticulumTransport / LXMRouter /
//  NetworkInterface / etc., and those modules are not even linked into the NE.
//  All reticulum-swift / LXMF-swift types below are referenced UNQUALIFIED (only
//  ReticulumSwift + LXMFSwift are in scope, so they are unambiguous), matching
//  `AppGroupBridgeInterface.swift`. Do NOT add `import Network` /
//  `import NetworkExtension` here: in that combination `NWPath` is ambiguous, and
//  this file needs neither.
//
//  ── NO-PII CONTRACT ──────────────────────────────────────────────────────────
//  All logging goes through `ExtensionDiagLog.log` (never NSLog directly here),
//  and carries envelope / metadata only: destination-hash SHORT PREFIXES
//  (≤ 8 hex chars), never plaintext, never private-key / full-identity material,
//  never host / port / on-device paths. The local notification carries at most a
//  short sender-hash prefix as title and a truncated content preview as body.
//

import Foundation
import UserNotifications
import ReticulumSwift
import LXMFSwift

/// In-NE Reticulum + LXMF node. Owns a `ReticulumTransport`, an `LXMRouter` (and
/// its GRDB store), the `lxmf.delivery` destination, and the App-Group bridge
/// interface, and turns inbound LXMF deliveries into a persisted message (done by
/// LXMF-swift) plus a local notification + DB-changed Darwin notification.
///
/// An `actor` so its mutable stack (transport / router / destination) is isolated
/// across the async start/stop lifecycle without manual locking.
actor NEReticulumNode {

    // MARK: - Model B gate

    /// Master gate for the Model B in-NE node. While `false`, the node must NOT
    /// be started from `startTunnel` — the live PoC dumb-pipe
    /// (`PacketTunnelProvider`'s NWConnection forwarding) is still the shipping
    /// path and the two would run-conflict (double-binding interfaces, duplicate
    /// delivery). Track C3 flips this to `true` and wires `start()` live in place
    /// of the dumb-pipe. Keep `false` until then.
    static let modelBNodeEnabled = false

    // MARK: - Keychain identity coordinates (MUST match the app's A3 code)
    //
    // The app (ColumbaApp `AppServices` / `IdentityManager`, via RNSAPI's
    // `Identity.saveToKeychain(service:account:accessGroup:)`) stores the raw
    // 64-byte RNS private-key blob as a `kSecClassGenericPassword` item under
    // these exact service / account names, in the SHARED keychain access group
    // so this extension can read the SAME identity. We replicate the read here
    // (rather than calling app code, which lives in the app target and imports
    // RNSAPI) via a direct `SecItemCopyMatching`.

    /// Keychain `kSecAttrService` — matches `AppServices.keychainService`.
    private static let keychainService = "com.columba.identity"
    /// Keychain `kSecAttrAccount` — matches `AppServices.keychainAccount`.
    private static let keychainAccount = "reticulum-identity"
    /// Suffix of the shared keychain access group — matches
    /// `AppServices.keychainGroupSuffix`. The full group is
    /// `<app-id-prefix>.network.columba.Columba.shared`, where the team-id
    /// prefix is resolved at runtime (never hardcoded — no deployment PII).
    private static let keychainGroupSuffix = "network.columba.Columba.shared"

    // MARK: - Darwin notification posted to the app on new inbound message
    //
    // The app's `NotificationObserver` (app target, imports RNSAPI) observes this
    // exact Darwin notification name and refreshes the message UI when it fires
    // (see `ChatsViewModel.onNewMessage`). The app's own inbound path posts it via
    // `NotificationObserver.postNewMessage()`. We can't call that type from the NE,
    // so we post the identical raw name directly, mirroring how
    // `AppGroupBridgeInterface` posts its Darwin notifications.

    /// Must equal `NotificationObserver.newMessageNotification`
    /// (`"network.columba.newMessage"`).
    private static let newMessageDarwinName = "network.columba.newMessage"

    // MARK: - Local-notification identifiers

    /// `UNUserNotificationCenter` request identifier prefix for inbound-message
    /// notifications posted by the NE. `fileprivate` so `NEDeliveryDelegate`
    /// (a separate type in this file) can read it.
    fileprivate static let notificationIdPrefix = "ne.lxmf.inbound."

    // MARK: - Stack (reticulum-swift / LXMF-swift), unqualified per the collision rule

    private var identity: Identity?
    private var pathTable: PathTable?
    private var transport: ReticulumTransport?
    private var router: LXMRouter?
    private var deliveryDestination: Destination?
    private var bridge: AppGroupBridgeInterface?

    /// Retained so the @MainActor delegate isn't deallocated while the router
    /// holds it weakly.
    private var delegate: NEDeliveryDelegate?

    /// `true` once `start()` has fully wired the node. Guards against double-start.
    private(set) var isRunning = false

    init() {}

    // MARK: - Lifecycle

    /// Bring up the in-NE Reticulum + LXMF node. Mirrors `SwiftRNSBackend.start()`.
    ///
    /// Returns `false` (a no-op) when the shared identity can't be read yet (the
    /// app hasn't created it) — the caller should treat that as "not ready",
    /// never as a crash. Throws only on a genuine setup failure (router/db open).
    ///
    /// NOTE: callers in `startTunnel` MUST gate this behind
    /// `NEReticulumNode.modelBNodeEnabled` (currently `false`) — see the type doc.
    @discardableResult
    func start() async throws -> Bool {
        guard !isRunning else { return true }

        // 1. Shared identity from the app's keychain group. Absent ⇒ app hasn't
        //    created one yet; bail cleanly (no notification, no crash).
        guard let id = Self.loadSharedIdentity() else {
            ExtensionDiagLog.log("NEReticulumNode: shared identity unavailable — not starting (app has not created it yet)")
            return false
        }
        self.identity = id

        // 2. App-Group GRDB store path (LXMF-swift owns the store at this path).
        let dbPath = Self.appGroupLXMFDatabasePath(identityHashHex: id.hexHash)
        ExtensionDiagLog.log("NEReticulumNode: starting (identity=\(Self.hashPrefix(id.hexHash)))")

        // 3. Path table + transport (mirror SwiftRNSBackend.start step 2).
        let pt = PathTable()
        self.pathTable = pt
        let tp = ReticulumTransport(pathTable: pt)
        self.transport = tp
        await tp.registerPathRequestHandler()

        // 4. LXMRouter — owns its own LXMF GRDB store at `dbPath` and persists
        //    validated inbound messages automatically before the delegate fires
        //    (mirror SwiftRNSBackend.start step 3).
        let rt = try await LXMRouter(identity: id, databasePath: dbPath)
        self.router = rt

        // 5. lxmf.delivery destination + ratchets (mirror step 4).
        let dest = Destination(
            identity: id, appName: "lxmf", aspects: ["delivery"], type: .single, direction: .in
        )
        self.deliveryDestination = dest
        await tp.registerDestination(dest)
        let ratchetPath = Self.appGroupRatchetStoragePath(identityHashHex: id.hexHash)
        try await dest.enableRatchets(storagePath: ratchetPath)

        // 6. Wire router → transport + ratchets + delivery + delegate (mirror step 5).
        await rt.setTransport(tp)
        await rt.setRatchetManager(dest.ratchetManager)
        try await rt.registerDeliveryDestination(dest)
        let d = await MainActor.run { NEDeliveryDelegate() }
        self.delegate = d
        await rt.setDelegate(d)

        // 7. Register the App-Group bridge interface so the NE's transport is
        //    reachable over the app's radios (BLE mesh / RNode) via the IPC
        //    queues. `hwMtu` here is a conservative placeholder; C3 supplies the
        //    active radio's negotiated MTU when it wires the relay live.
        //    The bridge `connect()`s itself when `addInterface` runs it.
        let br = AppGroupBridgeInterface(
            appGroupIdentifier: appGroupIdentifier,
            targetRadio: .bleMesh,
            hwMtu: Self.bridgePlaceholderHWMTU
        )
        self.bridge = br
        do {
            try await tp.addInterface(br)
        } catch {
            // Non-fatal: the node can still deliver over TCP once C3 wires it.
            ExtensionDiagLog.log("NEReticulumNode: AppGroupBridge addInterface failed (non-fatal): \(String(describing: error))")
        }

        // TODO(C3): add the live TCP / relay interface here (mirror
        // SwiftRNSBackend.start step 6.5 / `buildAndAdd`, reading the App-Group
        // interface configs from `SharedDefaultsConstants.interfacesKey`). Not
        // done in A5a: it must replace — not run alongside — the live PoC
        // NWConnection dumb-pipe in `PacketTunnelProvider`, which is the whole
        // reason the node is gated off behind `modelBNodeEnabled` for now. The
        // interface that A5a registers is the AppGroupBridgeInterface above.

        isRunning = true
        ExtensionDiagLog.log("NEReticulumNode: started (delivery dest=\(Self.hashPrefix(dest.hexHash)))")
        return true
    }

    /// Tear the node down. Mirrors `SwiftRNSBackend.stop()`'s teardown (drop the
    /// stack so the actors deinit). Best-effort and idempotent.
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        if let br = bridge {
            await br.disconnect()
        }
        router = nil
        transport = nil
        pathTable = nil
        deliveryDestination = nil
        bridge = nil
        delegate = nil
        identity = nil
        ExtensionDiagLog.log("NEReticulumNode: stopped")
    }

    // MARK: - Shared identity (replicates the app's A3 keychain read)

    /// Read the raw 64-byte RNS private key from the SHARED keychain access group
    /// (the same `service` / `account` / `accessGroup` the app's A3 code writes)
    /// and construct a `ReticulumSwift.Identity` from it. Returns `nil` when no
    /// item is present (app hasn't created the identity yet) or the access group
    /// can't be resolved (e.g. unsigned/simulator build with no entitlement).
    ///
    /// Replicates RNSAPI's `Identity.loadFromKeychain(service:account:accessGroup:)`
    /// query directly — we must NOT import RNSAPI here (collision rule), and that
    /// overload lives in the RNSAPI Compat layer.
    static func loadSharedIdentity() -> Identity? {
        guard let accessGroup = sharedKeychainAccessGroup() else {
            ExtensionDiagLog.log("NEReticulumNode: shared keychain access group unresolved (unsigned build?) — cannot load identity")
            return nil
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        query[kSecAttrAccessGroup as String] = accessGroup

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                ExtensionDiagLog.log("NEReticulumNode: keychain item present but not Data — identity load failed")
                return nil
            }
            do {
                return try Identity(privateKeyBytes: data)
            } catch {
                ExtensionDiagLog.log("NEReticulumNode: identity bytes rejected by Identity(privateKeyBytes:): \(String(describing: error))")
                return nil
            }
        case errSecItemNotFound:
            return nil
        default:
            // Log the OSStatus code only (a small integer — no PII).
            ExtensionDiagLog.log("NEReticulumNode: keychain read failed (OSStatus=\(status))")
            return nil
        }
    }

    /// The shared keychain access group, resolved at runtime so the team-id
    /// prefix isn't hardcoded (no deployment PII). Mirrors
    /// `AppServices.sharedKeychainAccessGroup()`. Returns `nil` on unsigned /
    /// simulator builds where the entitlement isn't enforced.
    private static func sharedKeychainAccessGroup() -> String? {
        guard let prefix = keychainAccessGroupPrefix() else { return nil }
        return "\(prefix).\(keychainGroupSuffix)"
    }

    /// Resolve the app-identifier (team-id) prefix by reading the access group
    /// the system assigns to a fresh generic-password probe item (the standard
    /// "bundle seed id" probe). Mirrors `AppServices.keychainAccessGroupPrefix()`.
    private static func keychainAccessGroupPrefix() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "columba.bundleSeedProbe",
            kSecAttrService as String: "columba.bundleSeedProbe",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(probe as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = group.components(separatedBy: ".").first,
              !prefix.isEmpty else {
            return nil
        }
        return prefix
    }

    // MARK: - App-Group paths
    //
    // The app's `AppServices.grdbDatabaseFilePath(for:)` roots the canonical LXMF
    // store at `<Application Support>/Columba/python-<identityHashHex>/lxmf-swift.db`.
    // That directory is PROCESS-LOCAL (the app and the NE have different
    // Application Support containers), so the NE cannot reach the app's copy.
    // For Model B the canonical store lives in the SHARED App-Group container so
    // BOTH processes open the same GRDB file; the per-identity `python-<hash>`
    // subdirectory layout and the `lxmf-swift.db` filename are preserved exactly
    // so `MessageRepository(grdbPath:)` resolves to the identical file. This is
    // the path the app converges onto under the App-Group-sharing work (A2 / the
    // LXMF-swift `feat/lxmfdb-appgroup-sharing` branch); A5a writes here so NE
    // deliveries land in the shared store the UI reads.

    /// Path to the App-Group-shared canonical `lxmf-swift.db` for `identityHashHex`
    /// (the raw identity hash — NOT the lxmf.delivery destination hash, matching
    /// `AppServices.grdbDatabaseFilePath(for:)`). Falls back to the NE's temporary
    /// directory if the App-Group container is unavailable (shouldn't happen in
    /// production — same fallback posture as `SharedFrameQueue`).
    static func appGroupLXMFDatabasePath(identityHashHex: String) -> String {
        let dir = appGroupColumbaSubdirectory(named: "python-\(identityHashHex)")
        return dir.appendingPathComponent("lxmf-swift.db").path
    }

    /// Path to the App-Group-shared ratchet storage for `identityHashHex`,
    /// alongside the GRDB store so all per-identity state co-locates in the shared
    /// container. (`SwiftRNSBackend` keeps ratchets next to its db under
    /// `configDir`; we mirror that under the App-Group `python-<hash>` dir.)
    static func appGroupRatchetStoragePath(identityHashHex: String) -> String {
        let dir = appGroupColumbaSubdirectory(named: "python-\(identityHashHex)")
        return dir.appendingPathComponent("ratchets").path
    }

    /// Resolve (creating if needed) `<App-Group container>/Columba/<named>/`.
    private static func appGroupColumbaSubdirectory(named name: String) -> URL {
        let base: URL
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            base = container
        } else {
            // Fallback (shouldn't happen in production with the App-Group
            // entitlement present). No path is logged — NO-PII.
            ExtensionDiagLog.log("NEReticulumNode: App-Group container unavailable — falling back to tmp for the LXMF store")
            base = FileManager.default.temporaryDirectory
        }
        let dir = base
            .appendingPathComponent("Columba", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Helpers

    /// Conservative placeholder hardware MTU for the bridge interface until C3
    /// supplies the active radio's negotiated MTU. Sized for a typical BLE-mesh
    /// payload so the link MDU never exceeds what the radio can carry.
    private static let bridgePlaceholderHWMTU = 500

    /// Short, NO-PII hash prefix (≤ 8 hex chars) for logging.
    fileprivate static func hashPrefix(_ hex: String) -> String {
        String(hex.prefix(8))
    }
}

// MARK: - NEDeliveryDelegate

/// LXMRouter delegate for the in-NE node. Mirrors `SwiftRNSBackend.RouterDelegate`,
/// but instead of bridging callbacks onto a `BackendEvent` stream it does the two
/// things the NE owns under Model B:
///   1. inbound message ⇒ post a local `UNUserNotification` (short sender-hash
///      prefix + truncated preview, honoring the host's notification
///      authorization), then post the DB-changed Darwin notification so the app
///      refreshes its message list;
///   2. all other states (sent / delivered / failed / sync) ⇒ log via
///      `ExtensionDiagLog` only — no notification.
///
/// By the time `didReceiveMessage` fires, LXMF-swift has ALREADY validated the
/// message (signature / duplicate / stamp) and PERSISTED it to its GRDB store
/// (see `LXMRouterDelegate.router(_:didReceiveMessage:)` docs) — so this delegate
/// does NOT persist; it only notifies.
///
/// `@MainActor` as required by `LXMRouterDelegate` (and so UN APIs are touched on
/// the main actor, matching the app's `NotificationService`).
@MainActor
private final class NEDeliveryDelegate: LXMRouterDelegate {

    /// Max characters of message content surfaced in the notification body.
    /// Short by design — NO full plaintext beyond a brief preview (NO-PII posture
    /// for envelope metadata; the body itself is user-facing, so a preview is
    /// acceptable, but kept minimal).
    private static let previewLimit = 80

    func router(_ router: LXMRouter, didReceiveMessage message: LXMessage) {
        // LXMF-swift already persisted `message` to the shared GRDB store.
        let senderHexPrefix = NEReticulumNode.hashPrefix(message.sourceHash.hexHash)
        ExtensionDiagLog.log("NEReticulumNode: inbound message persisted (from=\(senderHexPrefix))")

        // Snapshot the fields needed off the message before hopping into the
        // detached notification Task (LXMessage is a value type here).
        let contentPreview = Self.previewText(from: message.content)
        let threadId = message.sourceHash.hexHash

        // Post the local notification honoring system authorization. Fire-and-
        // forget; failures are logged but never propagate (a missed notification
        // must not destabilize delivery).
        Task {
            await Self.postInboundNotification(
                senderHexPrefix: senderHexPrefix,
                preview: contentPreview,
                threadId: threadId
            )
        }

        // Tell the app to refresh (same Darwin channel the app's own inbound path
        // uses). Posted regardless of notification authorization — the in-app UI
        // refresh is independent of the user's notification permission.
        Self.postNewMessageDarwinNotification()
    }

    func router(_ router: LXMRouter, didUpdateMessage message: LXMessage) {
        // Outbound state transitions aren't the NE's concern in A5a (the NE
        // delivers inbound; outbound sending is the app's path until A5b/A5c).
        // Log envelope only.
        if message.state == .delivered {
            ExtensionDiagLog.log("NEReticulumNode: outbound message delivered (hash=\(NEReticulumNode.hashPrefix(message.hash.hexHash)))")
        }
    }

    func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError) {
        ExtensionDiagLog.log("NEReticulumNode: message failed (hash=\(NEReticulumNode.hashPrefix(message.hash.hexHash)))")
    }

    func router(_ router: LXMRouter, didConfirmDelivery messageHash: Data) {
        ExtensionDiagLog.log("NEReticulumNode: delivery confirmed (hash=\(NEReticulumNode.hashPrefix(messageHash.hexHash)))")
    }

    // didUpdateSyncState / didCompleteSyncWithNewMessages: use the protocol's
    // default no-op implementations (no propagation sync in A5a).

    // MARK: - Notification

    /// Post a local notification for an inbound message, gated on the host's
    /// notification authorization. Title is a short sender-hash prefix; body is a
    /// truncated content preview. Grouped per-conversation via `threadIdentifier`.
    private static func postInboundNotification(
        senderHexPrefix: String,
        preview: String,
        threadId: String
    ) async {
        let center = UNUserNotificationCenter.current()

        // Honor the host's authorization: only `.authorized` posts. We do NOT
        // request authorization from the NE (the app owns the prompt) and we do
        // NOT read the app's per-type notification preference UserDefaults here —
        // A5a keeps the NE-side notification minimal; richer preference handling
        // can mirror `NotificationService` later if needed.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            ExtensionDiagLog.log("NEReticulumNode: notifications not authorized — skipping local notification")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "[\(senderHexPrefix)…]"
        content.body = preview.isEmpty ? "New message" : preview
        content.threadIdentifier = threadId
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: NEReticulumNode.notificationIdPrefix + UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        do {
            try await center.add(request)
        } catch {
            ExtensionDiagLog.log("NEReticulumNode: failed to post local notification: \(String(describing: error))")
        }
    }

    /// Build a short, UTF-8 content preview (truncated). Non-UTF-8 / empty content
    /// yields an empty string (caller substitutes a generic body).
    private static func previewText(from content: Data) -> String {
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else {
            return ""
        }
        if text.count <= previewLimit { return text }
        return String(text.prefix(previewLimit)) + "…"
    }

    /// Post the DB-changed Darwin notification the app's `NotificationObserver`
    /// listens for. Mirrors `AppGroupBridgeInterface`'s Darwin-post pattern;
    /// posts the identical raw name `NotificationObserver` uses, since that type
    /// (app target / RNSAPI) isn't reachable from the NE.
    private static func postNewMessageDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(NEReticulumNode.newMessageDarwinNameCF),
            nil,
            nil,
            true
        )
    }
}

// MARK: - Local hex helper
//
// LXMF-swift / reticulum-swift expose `Data.hexHash` (see `SwiftRNSBackend`'s
// local equivalent), but to avoid depending on whether that extension is `public`
// in the linked versions, define a small file-local one. Named distinctly so it
// can't collide if a public `hexHash` is also visible.
private extension Data {
    var hexHash: String { map { String(format: "%02x", $0) }.joined() }
}

fileprivate extension NEReticulumNode {
    /// `CFString` form of the DB-changed Darwin notification name. `fileprivate`
    /// so `NEDeliveryDelegate` (a separate type in this file) can read it; the
    /// same-file, same-type extension can still see the `private`
    /// `newMessageDarwinName` it wraps.
    static var newMessageDarwinNameCF: CFString { newMessageDarwinName as CFString }
}
