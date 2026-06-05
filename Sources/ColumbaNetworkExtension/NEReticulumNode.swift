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
//  SCOPE (A5a + C3):
//    • node setup (transport / router / delivery destination),
//    • shared-identity load from the App's keychain group,
//    • App-Group GRDB path computation (LXMF-swift owns the store),
//    • AppGroupBridgeInterface registration on the transport,
//    • live TCP/relay interface registration (Track C3) reading the relay config
//      from the App-Group `interfacesKey` (the SAME config the PoC reads),
//    • inbound delivery → (LXMF-swift persists) → local notification + DB-changed
//      Darwin notification so the app refreshes,
//    • app→NE IPC dispatch (A5b) + durable-outbox drain (A5c).
//  Follow-up (TODO(C3-followup)): Auto/multicast + non-TCP interface kinds, and
//  WiFi↔cellular path-change reconnect parity with the PoC path.
//
//  GATING (unified switch, Track C3): activation is guarded behind
//  `NEReticulumNode.modelBNodeEnabled`, now a RUNTIME read of the SHARED App-Group
//  flag `modelBBackgroundNE` — the SAME key `BackendPreference.modelB` reads, so
//  the app (ProxyRnsBackend selection) and the NE (this node) share ONE switch.
//  **It DEFAULTS FALSE**: while off, the node is NOT started from `startTunnel`
//  and the PoC dumb-pipe (`PacketTunnelProvider`'s NWConnection path) remains the
//  shipping fallback — starting the node alongside it would run-conflict
//  (double-binding the relay, duplicate delivery). When the user flips the flag
//  `true` (opt-in device-test), the node becomes the live delivery path and the
//  PoC `applyConfigs()` is skipped (see `PacketTunnelProvider.startTunnel`).
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
//  this file needs neither — the C3 TCP-relay path reads the endpoint as a plain
//  Foundation `(String, UInt16)` and hands it to reticulum-swift's `TCPInterface`
//  (which owns the socket internally), so no `Network` type ever crosses here.
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

    /// Master gate for the Model B in-NE node. Hardcoded `true`: Model B is the
    /// SOLE architecture on the build that compiles the NE in
    /// (ENABLE_NETWORK_EXTENSION ⇔ COLUMBA_BACKEND_SWIFT) — the extension exists
    /// solely to own this node. Mirrors the app-side `BackendPreference.modelB`,
    /// which is likewise build-flag `true`.
    ///
    /// (Formerly a runtime read of the shared App-Group flag `modelBBackgroundNE`;
    /// hardcoding it removed the cross-process flag race that used to leave the NE
    /// in sniff mode while the app came up as the proxy → `ipcFailed`. The PoC
    /// dumb-pipe it used to gate has since been deleted from `PacketTunnelProvider`.)
    static var modelBNodeEnabled: Bool {
        return true
    }

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
    /// Model B BLE: reticulum-swift's `BLEInterface` runs here, driven by an
    /// `AppGroupBLEDriver` that marshals the `BLEDriver` seam to the app (which
    /// owns CoreBluetooth). Retained so they outlive `start()`.
    private var bleSeamTransport: AppGroupBLESeamTransport?
    private var bleInterface: BLEInterface?

    /// Retained so the @MainActor delegate isn't deallocated while the router
    /// holds it weakly.
    private var delegate: NEDeliveryDelegate?

    /// Periodic self-announce loop. Model B: the NE owns `lxmf.delivery` and the
    /// app may be suspended, so the node must announce its OWN delivery destination
    /// (on start, once the relay connects, then on the user's interval) — otherwise
    /// peers/transport nodes never learn a path to it. Cancelled in `stop()`.
    private var announceTask: Task<Void, Never>?

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
    /// `NEReticulumNode.modelBNodeEnabled` (the runtime App-Group flag, default
    /// `false`) and, when active, skip the PoC `applyConfigs()` so the relay isn't
    /// double-bound — see the type doc and `PacketTunnelProvider.startTunnel`.
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
        //    queues. `hwMtu` here is a conservative placeholder; a follow-up can
        //    supply the active radio's negotiated MTU (TODO(C3-followup)).
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
            // Non-fatal: the node can still deliver over the TCP relay (below).
            ExtensionDiagLog.log("NEReticulumNode: AppGroupBridge addInterface failed (non-fatal): \(String(describing: error))")
        }

        // Model B BLE mesh: run reticulum-swift's `BLEInterface` here — it owns
        // fragmentation, per-peer `BLEPeerInterface` spawning, and the identity
        // handshake — driven by an `AppGroupBLEDriver` that marshals the `BLEDriver`
        // seam to the app process, which runs the real `CoreBluetoothBLEDriver`
        // (the NE sandbox can't drive CoreBluetooth). `BLEInterface` spawns a
        // `BLEPeerInterface` per connected peer; register/unregister those on the
        // transport via the peer callbacks. Supersedes the AppGroupBridge's BLE-mesh
        // role above; retire that once this path is validated on-device (TODO).
        ExtensionDiagLog.log("NEReticulumNode: BLE setup begin (identity=\(id.hash.count)B)")
        // `BLEInterface` preconditions a 16-byte identity — guard so a bad length
        // can't crash the NE on start.
        if id.hash.count == 16 {
            let bleTx = AppGroupBLESeamTransport(role: .networkExtension)
            bleTx.start()
            self.bleSeamTransport = bleTx
            let bleCfg = InterfaceConfig(
                id: "ne-ble-mesh", name: "BLE Mesh", type: .ble,
                enabled: true, mode: .full, host: "", port: 0
            )
            let bleIface = BLEInterface(
                config: bleCfg,
                driver: AppGroupBLEDriver(transport: bleTx),
                transportIdentity: id.hash
            )
            // `Task.detached` (NOT a bare `Task {}`): a bare task inherits this
            // node-actor's executor, which is kept continuously busy servicing the
            // app's proxy IPC — so the registration would starve and never run.
            await bleIface.setPeerCallbacks(
                onPeerAdded: { peer in Task.detached { try? await tp.addInterface(peer) } },
                onPeerRemoved: { peerId in Task.detached { await tp.removeInterface(id: peerId) } }
            )
            self.bleInterface = bleIface
            ExtensionDiagLog.log("NEReticulumNode: BLE interface built; registering off the critical path")
            // OFF THE CRITICAL PATH: `addInterface` → `BLEInterface.connect()` must
            // never gate the node's delivery bring-up (the TCP relay below). Even if
            // BLE setup stalls, the node still delivers over the relay.
            Task.detached {
                do {
                    try await tp.addInterface(bleIface)
                    ExtensionDiagLog.log("NEReticulumNode: BLE mesh interface registered (driver seam)")
                } catch {
                    ExtensionDiagLog.log("NEReticulumNode: BLE addInterface failed (non-fatal): \(String(describing: error))")
                }
            }
        } else {
            ExtensionDiagLog.log("NEReticulumNode: BLE skipped — identity not 16 bytes (\(id.hash.count))")
        }

        // C3: live TCP / relay interface. Read the relay config from the SAME
        // App-Group UserDefaults the PoC dumb-pipe reads
        // (`SharedDefaultsConstants.interfacesKey`), construct a reticulum-swift
        // `TCPInterface` to it, and register it on the transport. `addInterface`
        // sets the delegate + `connect()`s the interface itself (same as the
        // AppGroupBridge above), so the node OWNS this relay connection. When the
        // node is active `PacketTunnelProvider` skips its PoC `applyConfigs()` so
        // there's no double-bound relay socket (see `startTunnel`). Mirrors
        // `SwiftRNSBackend.buildAndAdd`'s `.tcpClient` case.
        //
        // SCOPE: only the TCP (`tcpClient`) relay is wired live here. Auto /
        // multicast and the other interface kinds the app supports are a
        // follow-up (TODO(C3-followup)); the AppGroupBridge above already carries
        // the app's radios (BLE mesh / RNode) into the node.
        // iOS NE egress fix (see reticulum-swift port-deviations.md): prohibit
        // the virtual (.other = our own utun packet tunnel) interface on the
        // relay's NWConnection so it egresses a physical interface (wifi/
        // cellular) and actually reaches the relay — a stock NWParameters.tcp
        // connection created inside the provider reports a phantom `.ready` but
        // produces no SYN/socket on the relay host (verified on-device via
        // tcpdump+lsof), black-holed in our own tunnel. Process-global; set
        // before the interface connects.
        TCPTransport.bypassTunnelEgress = true

        if let tcp = Self.loadTCPRelayConfig() {
            do {
                let cfg = InterfaceConfig(
                    id: "ne-tcp-relay",
                    name: "NE TCP Relay",
                    type: .tcp,
                    enabled: true,
                    mode: .full,
                    host: tcp.host,
                    port: tcp.port
                )
                let tcpIface = try TCPInterface(config: cfg)
                try await tp.addInterface(tcpIface)
                // NO-PII: never log tcp.host / tcp.port (the relay endpoint).
                ExtensionDiagLog.log("NEReticulumNode: TCP relay interface registered")
            } catch {
                // Non-fatal: the node can still deliver over the AppGroupBridge
                // (radio) even if the relay socket can't be brought up.
                ExtensionDiagLog.log("NEReticulumNode: TCP relay addInterface failed (non-fatal): \(String(describing: error))")
            }
        } else {
            ExtensionDiagLog.log("NEReticulumNode: no TCP relay configured — node running on AppGroupBridge only")
        }

        // TODO(C3-followup): reconnect parity. The PoC path
        // (`PacketTunnelProvider`) drives capped-backoff reconnects + a path
        // monitor for its relay socket; reticulum-swift's `TCPInterface` has its
        // own `ExponentialBackoff` auto-reconnect, so the node's relay self-heals,
        // but it does NOT yet react to a WiFi↔cellular path change the way the PoC
        // path-monitor does. Acceptable for device-testing; wire a path-change
        // rebind here if interface switches prove flaky under Model B.

        isRunning = true
        ExtensionDiagLog.log("NEReticulumNode: started (delivery dest=\(Self.hashPrefix(dest.hexHash)))")

        // 7b. Self-announce. In Model B the NE owns `lxmf.delivery` and the app may
        //     be suspended, so the node announces its OWN delivery destination —
        //     peers/transport nodes learn the path from this. Wait for the relay to
        //     connect (so the first announce traverses TCP, not just the radio
        //     bridge), then re-announce on the user's configured interval.
        //
        // 7c. Re-announce whenever the relay (re)connects. A relay that restarted
        //     loses its path table, so without this our delivery dest would be
        //     unreachable until the periodic interval elapsed. Mirrors the app's
        //     AutoAnnounceManager "on TCP reconnect" trigger; reticulum-swift
        //     rate-limits announces per interface, so a flapping link can't spam.
        await tp.setOnInterfaceConnected { [weak self] interfaceId in
            guard interfaceId == "ne-tcp-relay" else { return }
            await self?.onRelayReconnected()
        }
        startAnnounceScheduler()

        // 8. A5c — drain the durable App-Group outbox. While the NE was down the
        //    app persisted any outbound LXMF sends here (ProxyRnsBackend on IPC
        //    failure); now that transport + router + delivery destination are up,
        //    replay each one through the same `sendLxmfForIPC(...)` path a live IPC
        //    send would take. Re-sending is safe: LXMF-swift dedups inbound by
        //    message hash receiver-side, and we only enqueue sends the NE never
        //    accepted. Failures are logged + skipped (the rest still drain) — we do
        //    NOT re-append, because `drainAll()` already cleared the file and a
        //    `handleOutbound` throw is a pack/sign error that a verbatim retry on
        //    the next start would just hit again (an unbounded requeue loop). This
        //    is the simpler correct option; the cost is dropping an entry that
        //    cannot be packed at all, which the optimistic UI row will surface as
        //    not-delivered. Run after `isRunning = true` so the node is observably
        //    started even if the drain is slow.
        await drainOutbox()

        return true
    }

    /// Replay every entry the app persisted to the durable App-Group outbox while
    /// the NE was down (A5c). Called at the end of `start()`. NO-PII: logs counts
    /// and dest-hash short prefixes only.
    private func drainOutbox() async {
        let pending = OutboxQueue().drainAll()
        guard !pending.isEmpty else { return }
        ExtensionDiagLog.log("NEReticulumNode: draining outbox (\(pending.count) pending send(s))")

        var sent = 0
        var failed = 0
        for entry in pending {
            // `sendLxmfForIPC` does not throw (it returns a `ProxySendOutcome`);
            // treat anything other than `.queued` as a failed replay for the count.
            let outcome = await sendLxmfForIPC(
                destHashHex: entry.destHashHex,
                content: entry.content,
                method: entry.method,
                fieldsData: entry.fieldsData ?? Data()
            )
            if outcome.kind == .queued {
                sent += 1
            } else {
                failed += 1
                ExtensionDiagLog.log("NEReticulumNode: outbox replay not queued (dest=\(Self.hashPrefix(entry.destHashHex)), kind=\(outcome.kind.rawValue)) — dropped")
            }
        }
        ExtensionDiagLog.log("NEReticulumNode: outbox drain complete (queued=\(sent), dropped=\(failed))")
    }

    /// Tear the node down. Mirrors `SwiftRNSBackend.stop()`'s teardown (drop the
    /// stack so the actors deinit). Best-effort and idempotent.
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        announceTask?.cancel()
        announceTask = nil
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
        // Prefer the group the APP resolved + shared via the App Group. The in-NE
        // keychain probe (below) is unreliable when the device is locked — exactly
        // when background delivery must run — and on first NE start before the app
        // has launched. The app (running unlocked) resolves it once and writes it
        // here, so the NE doesn't have to probe.
        if let shared = UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: "resolvedSharedKeychainGroup"), !shared.isEmpty {
            return shared
        }
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
    /// `AppServices.grdbDatabaseFilePath(for:)`). Delegates to the SHARED
    /// `AppGroupPaths` helper so the NE and the app provably compute the identical
    /// path (the whole point of A2). Falls back to the NE's temporary directory if
    /// the App-Group container is unavailable (shouldn't happen in production —
    /// same fallback posture as `SharedFrameQueue`).
    static func appGroupLXMFDatabasePath(identityHashHex: String) -> String {
        if let url = AppGroupPaths.lxmfDatabaseURL(identityHashHex: identityHashHex) {
            return url.path
        }
        return tmpFallbackDirectory(named: "python-\(identityHashHex)")
            .appendingPathComponent("lxmf-swift.db").path
    }

    /// Path to the App-Group-shared ratchet storage for `identityHashHex`,
    /// alongside the GRDB store so all per-identity state co-locates in the shared
    /// container. (`SwiftRNSBackend` keeps ratchets next to its db under
    /// `configDir`; we mirror that under the App-Group `python-<hash>` dir.)
    /// Delegates to the SHARED `AppGroupPaths` helper (see above).
    static func appGroupRatchetStoragePath(identityHashHex: String) -> String {
        if let url = AppGroupPaths.ratchetStorageURL(identityHashHex: identityHashHex) {
            return url.path
        }
        return tmpFallbackDirectory(named: "python-\(identityHashHex)")
            .appendingPathComponent("ratchets").path
    }

    /// Resolve (creating if needed) `<tmp>/Columba/<named>/`, used only when the
    /// App-Group container is unavailable (shouldn't happen in production with the
    /// App-Group entitlement present). No path is logged — NO-PII.
    private static func tmpFallbackDirectory(named name: String) -> URL {
        ExtensionDiagLog.log("NEReticulumNode: App-Group container unavailable — falling back to tmp for the LXMF store")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Columba", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Helpers

    /// Conservative placeholder hardware MTU for the bridge interface until a
    /// follow-up supplies the active radio's negotiated MTU (TODO(C3-followup)).
    /// Sized for a typical BLE-mesh payload so the link MDU never exceeds what the
    /// radio can carry.
    private static let bridgePlaceholderHWMTU = 500

    /// Read the enabled `tcpClient` relay endpoint from the SHARED App-Group
    /// UserDefaults (the same `SharedDefaultsConstants.interfacesKey` JSON the PoC
    /// dumb-pipe parses in `PacketTunnelProvider.loadInterfaceConfigs`). Returns
    /// the first enabled TCP relay's `(host, port)`, or `nil` if none is
    /// configured. Foundation-only JSON parse — the node does NOT import `Network`
    /// (collision rule), so it surfaces a plain `(String, UInt16)` that `start()`
    /// feeds to a reticulum-swift `TCPInterface`. NO-PII: never logs host/port.
    static func loadTCPRelayConfig() -> (host: String, port: UInt16)? {
        let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: SharedDefaultsConstants.interfacesKey),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for entity in array {
            guard let enabled = entity["enabled"] as? Bool, enabled,
                  let configWrapper = entity["config"] as? [String: Any],
                  let type = configWrapper["type"] as? String, type == "tcpClient",
                  let config = configWrapper["config"] as? [String: Any],
                  let host = config["targetHost"] as? String,
                  let port = config["targetPort"] as? Int else {
                continue
            }
            return (host: host, port: UInt16(truncatingIfNeeded: port))
        }
        return nil
    }

    /// Short, NO-PII hash prefix (≤ 8 hex chars) for logging.
    fileprivate static func hashPrefix(_ hex: String) -> String {
        String(hex.prefix(8))
    }

    // MARK: - A5b IPC dispatch (Model B app→NE send path)
    //
    // Thin node-ops invoked by `PacketTunnelProvider.handleAppMessage` when it
    // decodes a `ProxyRequest` envelope (see `ProxyIPC`, Shared/Foundation-only).
    // The app's `ProxyRnsBackend` marshals the matching `RnsBackend` methods to
    // these. Each returns a Foundation-only result the dispatcher encodes into a
    // `ProxyResponse`; node-not-running is handled by the dispatcher (it only
    // calls these on a non-nil, started node). These mirror the corresponding
    // `SwiftRNSBackend` methods, but here on the NE's own stack — keeping the
    // NE's RNSAPI-free collision posture (no RNSAPI types cross this boundary).
    //
    // SCOPE: the node is constructed/started only when `modelBNodeEnabled` is true
    // (the runtime App-Group flag, default `false`), so in the default shipping
    // build these are never reached; they go live when the user opts into Model B.

    /// Lowercase-hex of the learned `lxmf.delivery` destination + identity, for
    /// the `.start` response. `nil` before `start()`.
    func localInfoForIPC() -> ProxyLocalInfo? {
        guard let identity, let dest = deliveryDestination else { return nil }
        return ProxyLocalInfo(identityHash: identity.hexHash, destinationHash: dest.hexHash)
    }

    /// Emit an `lxmf.delivery` announce (mirrors `SwiftRNSBackend.announce`).
    /// Canonical LXMF (>= 0.5.0) app_data: msgpack([display_name_bytes, stamp_cost]).
    @discardableResult
    func announceForIPC(displayName: String) async -> Bool {
        // msgpack([display_name_utf8_bytes, null]) — stamp_cost nil, matching the
        // app-side `SwiftRNSBackend.announce`.
        let appData = packMsgPack(.array([.binary(Data(displayName.utf8)), .null]))
        return await emitAnnounceForIPC(on: deliveryDestination, appData: appData, withRatchet: true)
    }

    /// Telephony announce is out of A5b scope: the A5a node owns only the
    /// `lxmf.delivery` destination (no `lxst.telephony` destination), so there's
    /// nothing to announce here. Returns false so the proxy degrades cleanly.
    /// (Model B: telephony stays app-local / not owned by the NE node yet.)
    @discardableResult
    func announceTelephonyForIPC(displayName: String) async -> Bool {
        ExtensionDiagLog.log("NEReticulumNode: announceTelephony not owned by NE node (A5b) — no-op")
        return false
    }

    private func emitAnnounceForIPC(on destination: Destination?, appData: Data, withRatchet: Bool) async -> Bool {
        guard let transport, let destination else {
            ExtensionDiagLog.log("NEReticulumNode: emitAnnounce SKIPPED — node not started (no transport/destination)")
            return false
        }
        destination.appData = appData
        var ratchetPub: Data? = nil
        if withRatchet, let mgr = destination.ratchetManager {
            await mgr.rotateIfNeeded()
            ratchetPub = await mgr.currentRatchetPublicBytes()
        }
        do {
            let announce = Announce(destination: destination, ratchet: ratchetPub)
            let packet = try announce.buildPacket()
            try await transport.send(packet: packet)
            // Diagnostic: confirm the emit + show interface connection states — if the
            // TCP relay interface is "down" the announce can't reach the Mac even
            // though the socket is established.
            let snaps = await transport.getInterfaceSnapshots()
            let ifaces = snaps.map { "\($0.id.prefix(14))=\($0.state == .connected ? "conn" : "down")" }
                .joined(separator: ",")
            ExtensionDiagLog.log("NEReticulumNode: announce EMITTED dest=\(destination.hexHash.prefix(8)) \(packet.size)B ifaces=[\(ifaces)]")
            return true
        } catch {
            ExtensionDiagLog.log("NEReticulumNode: announce send failed: \(String(describing: error))")
            return false
        }
    }

    // MARK: - Self-announce (Model B)

    /// Launch the periodic self-announce loop. Idempotent: cancels any prior task.
    private func startAnnounceScheduler() {
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            guard let self else { return }
            // Wait for the relay to connect so the FIRST announce actually goes out
            // the TCP interface (transport-node path), not only the radio bridge.
            // Best-effort: if the relay never connects (radio-only node), announce
            // anyway once the timeout elapses.
            let connected = await self.waitForRelayConnected(timeoutMs: 15_000)
            ExtensionDiagLog.log("NEReticulumNode: announce scheduler — relay connected=\(connected) before first announce")
            await self.selfAnnounce()
            // Periodic re-announce on the user's configured interval (default 3h),
            // mirroring the app's AutoAnnounceManager cadence.
            while !Task.isCancelled {
                let hours = await self.configuredAnnounceIntervalHours()
                do {
                    try await Task.sleep(for: .seconds(hours * 3600))
                } catch {
                    return  // cancelled
                }
                if Task.isCancelled { return }
                await self.selfAnnounce()
            }
        }
    }

    /// Emit one `lxmf.delivery` announce using the user's shared display name.
    private func selfAnnounce() async {
        let ok = await announceForIPC(displayName: sharedDisplayName())
        ExtensionDiagLog.log("NEReticulumNode: self-announce (ok=\(ok))")
    }

    /// The relay interface reached `.connected` (initial connect, or a reconnect
    /// after the relay/daemon restarted). Re-announce so the relay relearns our
    /// delivery destination promptly. No-op once the node is torn down.
    private func onRelayReconnected() async {
        guard isRunning else { return }
        ExtensionDiagLog.log("NEReticulumNode: relay (re)connected — re-announcing delivery dest")
        await selfAnnounce()
    }

    /// Poll the transport's interface snapshots until the relay (`ne-tcp-relay`)
    /// reports `.connected`, or `timeoutMs` elapses. Returns whether it connected.
    private func waitForRelayConnected(timeoutMs: Int) async -> Bool {
        guard let transport else { return false }
        var waited = 0
        let stepMs = 500
        while waited < timeoutMs {
            let snaps = await transport.getInterfaceSnapshots()
            if snaps.contains(where: { $0.id == "ne-tcp-relay" && $0.state == .connected }) {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(stepMs))
            } catch {
                return false
            }
            waited += stepMs
        }
        return false
    }

    /// The user's announce display name from the shared App-Group defaults
    /// (`SettingsRepository` key `"displayName"`), falling back to the identity
    /// hash prefix (matching the app's anonymous-peer naming).
    private func sharedDisplayName() -> String {
        if let s = UserDefaults(suiteName: appGroupIdentifier)?.string(forKey: "displayName"),
           !s.isEmpty {
            return s
        }
        return String((identity?.hexHash ?? "").prefix(8))
    }

    /// The user's configured announce interval in hours (App-Group key
    /// `"announce_interval_hours"`, default 3), matching `AutoAnnounceManager`.
    private func configuredAnnounceIntervalHours() -> Int {
        let h = UserDefaults(suiteName: appGroupIdentifier)?.integer(forKey: "announce_interval_hours") ?? 0
        return h > 0 ? h : 3
    }

    /// Flush the router's pending state to its GRDB store
    /// (mirrors `SwiftRNSBackend.persist`).
    @discardableResult
    func persistForIPC() async -> Bool {
        await router?.persistPendingState()
        return true
    }

    /// Lowercase-hex destination hashes this node has registered — just the
    /// `lxmf.delivery` destination in A5a (no telephony destination on the NE
    /// node yet). Mirrors `SwiftRNSBackend.registeredDestinationHashes`.
    func registeredDestinationHashesForIPC() -> [String] {
        [deliveryDestination].compactMap { $0?.hexHash }
    }

    /// Transport diagnostic snapshot as a Foundation-only JSON object whose keys
    /// match `RNSAPI.StatusSnapshot`'s `snake_case` `CodingKeys`, so the app
    /// decodes the `.ok` payload straight into `StatusSnapshot`. We build the
    /// JSON inline (rather than encoding an RNSAPI type) to honor the collision
    /// rule (the NE never imports RNSAPI).
    func statusSnapshotJSONForIPC() async -> Data? {
        guard let transport else { return nil }
        let snaps = await transport.getInterfaceSnapshots()
        let interfaces: [[String: Any]] = snaps.map { s in
            [
                "section_name": s.id,
                "name": s.name,
                "online": s.state == .connected,
                "rx_bytes": 0,
                "tx_bytes": 0,
                // Model B: the app's Network Status view can't see the NE's transport,
                // so carry enough to reconstruct each interface row (type / peer / error).
                "type": s.type.rawValue,
                "is_ble_peer": s.isBLEPeerInterface,
                "is_auto_peer": s.isAutoInterfacePeer,
                "peer_address": s.peerAddress ?? "",
                "last_error": s.lastErrorDescription ?? "",
            ]
        }
        let destCount = await transport.destinationCount
        let pathCount = await transport.getPathTable().count
        let object: [String: Any] = [
            "started": identity != nil,
            "interfaces": interfaces,
            "destination_table_size": destCount,
            "path_table_size": pathCount,
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// Native Model B BLE peer snapshot. reticulum-swift's `BLEInterface` runs in
    /// the NE and owns the peers; map its `BLEConnectionInfo` onto the Codable
    /// `BLEPeerSnapshot` wire DTO so the app's BLE connections screen can render
    /// the real native peers (the app can't enumerate them — the radio + the
    /// `BLEInterface` both live across the seam). Returns JSON `[BLEPeerSnapshot]`,
    /// or nil when the BLE interface isn't up. See `ble_to_ne_driver_abstraction_plan`.
    func bleConnectionsJSONForIPC() async -> Data? {
        guard let bleInterface else { return nil }
        let infos = await bleInterface.getConnectionInfos()
        let snapshots: [BLEPeerSnapshot] = infos.map { info in
            BLEPeerSnapshot(
                identityHash: info.identityHash,
                isOutgoing: info.isOutgoing,
                rssi: info.rssi,
                mtu: info.mtu,
                connectedAt: info.connectedAt,
                lastActivity: info.lastActivity,
                bytesSent: info.bytesSent,
                bytesReceived: info.bytesReceived,
                packetsSent: info.packetsSent,
                packetsReceived: info.packetsReceived
            )
        }
        return try? JSONEncoder().encode(snapshots)
    }

    /// Heard-announce snapshot (Model B incoming-announce bridge). The NE owns
    /// the transport, so the app can't hear announces itself — it polls this and
    /// re-emits `.announce` events. Mirrors the PathTable read in
    /// `SwiftRNSBackend.startAnnouncePolling` (only entries whose aspect we
    /// recognise — lxmf.delivery / lxmf.propagation / lxst.telephony /
    /// nomadnetwork.node — carry a `detectedAspect`). Returns JSON
    /// `[ProxyHeardAnnounce]`.
    func heardAnnouncesJSONForIPC() async -> Data? {
        guard let pathTable else { return nil }
        let entries = await pathTable.allEntries()
        let announces: [ProxyHeardAnnounce] = entries.compactMap { entry in
            guard let aspect = entry.detectedAspect else { return nil }
            return ProxyHeardAnnounce(
                destHashHex: entry.destinationHash.hexHash,
                appDataHex: (entry.appData ?? Data()).hexHash,
                aspect: aspect,
                publicKeysHex: entry.publicKeys.hexHash,
                interfaceName: entry.interfaceId,
                hops: Int(entry.hopCount),
                timestamp: entry.timestamp.timeIntervalSince1970
            )
        }
        return try? JSONEncoder().encode(announces)
    }

    /// Send an LXMF message on the NE node (mirrors
    /// `SwiftRNSBackend.sendLxmfMessage`, but the field map arrives pre-packed as
    /// MessagePack `fieldsData` from the app — the NE unpacks it to `[UInt8: Any]`
    /// for `LXMessage.fields` rather than rebuilding it from typed params, since
    /// it can't import RNSAPI's `LxmfFieldCodec`). `method` is the
    /// `RNSAPI.LXDeliveryMethod` raw value string. Returns a Foundation-only
    /// `ProxySendOutcome`.
    func sendLxmfForIPC(destHashHex: String, content: String, method: String, fieldsData: Data) async -> ProxySendOutcome {
        guard let router, let id = identity else { return ProxySendOutcome(kind: .notStarted) }
        guard let destHash = Self.hexToData(destHashHex), !destHash.isEmpty else {
            return ProxySendOutcome(kind: .badHash)
        }
        let fields = Self.unpackFieldMap(fieldsData)
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: id,
            content: Data(content.utf8),
            title: Data(),
            fields: fields.isEmpty ? nil : fields,
            desiredMethod: Self.deliveryMethod(method)
        )
        do {
            try await router.handleOutbound(&msg)
            return ProxySendOutcome(kind: .queued, detail: msg.hash.hexHash)
        } catch {
            return ProxySendOutcome(kind: .other, detail: String(describing: error))
        }
    }

    // MARK: - A5b dispatch helpers

    /// Map the `RNSAPI.LXDeliveryMethod` raw value string to LXMF-swift's enum.
    /// Defaults to opportunistic for unknown/paper (matching `SwiftRNSBackend`'s
    /// `lxmfMethod`, which only distinguishes direct / propagated / else).
    private static func deliveryMethod(_ raw: String) -> LXDeliveryMethod {
        switch raw {
        case "direct":     return .direct
        case "propagated": return .propagated
        default:           return .opportunistic
        }
    }

    /// Unpack the app's MessagePack field bytes (produced by RNSAPI's
    /// `LxmfFieldCodec.pack`, standard MessagePack) into `[UInt8: Any]` for
    /// `LXMessage.fields`. Mirrors `LxmfFieldCodec.unpack`'s shape but uses
    /// reticulum-swift's `unpackMsgPack` (the NE can't import RNSAPI). Empty /
    /// malformed / non-map input yields an empty map.
    private static func unpackFieldMap(_ data: Data) -> [UInt8: Any] {
        guard !data.isEmpty, let value = try? unpackMsgPack(data), case .map(let m) = value else {
            return [:]
        }
        var out: [UInt8: Any] = [:]
        for (k, v) in m {
            guard let key = uint8Key(k) else { continue }
            out[key] = anyValue(from: v)
        }
        return out
    }

    /// Coerce a MessagePack map key to a `UInt8` LXMF field id.
    private static func uint8Key(_ v: MessagePackValue) -> UInt8? {
        switch v {
        case .uint(let u) where u <= UInt64(UInt8.max): return UInt8(u)
        case .int(let i) where i >= 0 && i <= Int64(UInt8.max): return UInt8(i)
        default: return nil
        }
    }

    /// Convert a `MessagePackValue` to the `Any` representation LXMF-swift's
    /// `LXMessage.fields` expects: `binary → Data`, `string → String`,
    /// `array → [Any]`, nested `map → [UInt8: Any]` (LXMF field sub-maps are
    /// id-keyed, e.g. FIELD_REACTION), scalars → their Swift value.
    private static func anyValue(from v: MessagePackValue) -> Any {
        switch v {
        case .null:            return NSNull()
        case .bool(let b):     return b
        case .int(let i):      return i
        case .uint(let u):     return u
        case .float(let f):    return f
        case .double(let d):   return d
        case .string(let s):   return s
        case .binary(let d):   return d
        case .array(let a):    return a.map { anyValue(from: $0) }
        case .map(let m):
            // Prefer a UInt8-keyed sub-map (LXMF sub-fields); fall back to a
            // string-keyed dictionary if the keys aren't field ids.
            var idKeyed: [UInt8: Any] = [:]
            var ok = true
            for (k, val) in m {
                if let key = uint8Key(k) { idKeyed[key] = anyValue(from: val) }
                else { ok = false; break }
            }
            if ok { return idKeyed }
            var strKeyed: [String: Any] = [:]
            for (k, val) in m {
                if case .string(let s) = k { strKeyed[s] = anyValue(from: val) }
            }
            return strKeyed
        }
    }

    /// Decode a hex string to `Data` (mirrors `SwiftRNSBackend.hexData`; the NE
    /// has no RNSAPI hex helper and reticulum-swift's would be ambiguous).
    private static func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
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
