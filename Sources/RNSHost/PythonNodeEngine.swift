// Shared Python RNS/LXMF engine. Exactly one process holds NodeProcessLease.
// Both hosts use the same lifecycle, native radios, durable inbox, and outbox.
// Keep this module independent of RNSAPI/ReticulumSwift/LXMFSwift: all command
// data crossing the app seam is represented by Foundation types.

import Foundation
import Security

/// One interpreter and engine per process; startup obtains exclusive ownership
/// before initializing RNS. Python calls acquire the interpreter's GIL.
final class PythonNodeEngine: @unchecked Sendable {

    /// True once `start()` has brought the Python RNS node up.
    private(set) var isRunning = false
    private let stateLock = NSLock()
    private let lifecycleLock = NSLock()
    private let processLease = NodeProcessLease()

    /// Durable outbox recovery + send-response-ambiguity dedup (P1 #3 + #6). Both
    /// backings live in the shared App-Group container (the same place the app
    /// appends the outbox), so a send recorded here is visible across an NE restart.
    /// The NE is the sole runtime, so it owns both the read (`replayOutbox` at
    /// start) and the dedup (`lxmfSend` consults `sentIds` before sending).
    private let outboxReplay = OutboxReplayCoordinator()

    /// The in-flight outbox-retry task (P1 #4). Non-nil while the node is up and
    /// the retry loop is armed. Guarded by `stateLock`; the task is cancelled in
    /// `stop()` so it can never outlive the node it is retrying for.
    private var replayRetryTask: Task<Void, Never>?
    private var propagationSyncTask: Task<Void, Never>?

    /// Cadence between outbox-retry passes while the node is running (P1 #4): a
    /// transient send failure (peer not connected yet, router not warm) is
    /// re-attempted on this schedule instead of waiting for the next start.
    private static let replayRetryIntervalNs: UInt64 = 5_000_000_000

    /// The shared keychain group the app stored the identity in (resolved once,
    /// so the keychain access-group probe isn't repeated on every start).
    private var cachedAccessGroup: String?

    private init() {}

    /// The engine instance owned by the running NE. Constructed lazily so the
    /// CPython interpreter is only touched from the tunnel provider's tasks.
    static let shared = PythonNodeEngine()

    // MARK: - Identity (shared keychain, Foundation-only read)
    //
    // The app stores the raw 64-byte RNS private-key blob as a
    // kSecClassGenericPassword item under service "com.columba.identity" /
    // account "reticulum-identity" in the SHARED keychain access group
    // (AppServices saves it there). We read the SAME item here (mirroring the
    // read the old NEReticulumNode did) so the Python engine starts with the
    // app's identity, without importing RNSAPI.

    private static let keychainService = "com.columba.identity"
    private static let keychainAccount = "reticulum-identity"
    private static let keychainGroupSuffix = "network.columba.Columba.shared"

    /// Read the app's shared identity blob (raw private-key bytes), or nil when
    /// the app hasn't created one yet (first launch) - the caller treats that
    /// as "not ready" and retries.
    func loadSharedIdentityBytes() -> Data? {
        let group = resolvedSharedKeychainGroup()
        guard let group else {
            ExtensionDiagLog.log("[NE-PY-RNS] shared keychain group unresolved - no identity")
            return nil
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecAttrAccessGroup as String: group,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else {
                ExtensionDiagLog.log("[NE-PY-RNS] keychain identity item present but empty")
                return nil
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            ExtensionDiagLog.log("[NE-PY-RNS] keychain identity read failed (OSStatus=\(item == nil ? "n/a" : "present"))")
            return nil
        }
    }

    /// The shared keychain access group, resolved at runtime (no hardcoded team
    /// prefix - no deployment PII). Prefers the value the app resolved + shared
    /// via App-Group UserDefaults; falls back to probing (mirrors the old
    /// NEReticulumNode resolution).
    private func resolvedSharedKeychainGroup() -> String? {
        if let cached = cachedAccessGroup, !cached.isEmpty { return cached }
        if let shared = UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: "resolvedSharedKeychainGroup"), !shared.isEmpty {
            cachedAccessGroup = shared
            return shared
        }
        guard let prefix = keychainAccessGroupPrefix() else { return nil }
        let group = "\(prefix).\(Self.keychainGroupSuffix)"
        cachedAccessGroup = group
        return group
    }

    /// Probe the keychain for the team-id prefix of this bundle's access group
    /// (a transient seed item, deleted after reading - mirrors
    /// AppServices.keychainAccessGroupPrefix).
    private func keychainAccessGroupPrefix() -> String? {
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
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "columba.bundleSeedProbe",
            kSecAttrService as String: "columba.bundleSeedProbe",
        ] as CFDictionary)
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = group.components(separatedBy: ".").first,
              !prefix.isEmpty else { return nil }
        return prefix
    }

    // MARK: - Node lifecycle

    /// Bring the Python RNS node up. Returns the local info JSON
    /// (`{"identity_hash":..., "destination_hash":...}`) on success, or nil
    /// when the app hasn't created a shared identity yet (the caller replies
    /// `.unsupported` so the app retries). Idempotent at the Python level
    /// (`rns_bridge.start` returns the existing local_info if already up).
    ///
    /// `displayName` rides in the `.start` request; it is passed to
    /// `rns_bridge.start` so the startup announce carries it.
    func start(displayName: String, host: NodeHostingMode = .networkExtension) -> String? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard NodeHostingMode.current == host, let root = AppGroupPaths.containerURL() else { return nil }
        let leaseURL = root.appendingPathComponent("rns-owner.lock")
        guard processLease.acquire(at: leaseURL) else {
            ExtensionDiagLog.log("[RNS-HOST] another process owns the node")
            return nil
        }
        var started = false
        var attemptedStart = false
        defer {
            if !started && !isRunning {
                // A failed Python start may have allocated interfaces. Release
                // ownership only after Python confirms its cleanup completed.
                if !attemptedStart {
                    processLease.release()
                } else if let reply = PythonNodeRuntime.shared.callBridge("stop", payload: "{}"), Self.parse(reply)?.ok == true {
                    processLease.release()
                }
            }
        }
        // A NEW node incarnation is beginning (the node is not currently
        // running) - invalidate any BLE events still queued from the previous
        // incarnation so a stale event (e.g. a "peer disconnected" from the old
        // node) is not delivered to THIS node's callbacks, where it could drop a
        // peer that is connected here. Only discard on a real (re)start: an
        // idempotent .start while the node is ALREADY running reuses the same
        // Python node (isRunning stays true), so its waiting BLE events are
        // still valid and must NOT be dropped. PythonNodeBridgeHook lives in the
        // same NE target. (iter-3 finding + iter-4 refinement.)
        stateLock.lock()
        let restarting = !isRunning
        stateLock.unlock()
        if restarting {
            PythonNodeBridgeHook.shared.discardPendingEvents()
        }
        if PythonNodeRuntime.shared.state != .running {
            // CPython not initialized yet (shouldn't happen - startTunnel boots
            // it) - try to init synchronously; if that fails we're not ready.
            if case .failure(let err) = PythonNodeRuntime.shared.start() {
                ExtensionDiagLog.log("[NE-PY-RNS] start: python not ready (init failed: \(err.localizedDescription))")
                return nil
            }
        }
        guard let identity = loadSharedIdentityBytes() else {
            ExtensionDiagLog.log("[NE-PY-RNS] start: no shared identity yet - not ready")
            return nil
        }
        let configDir = Self.sharedConfigDir()
        // rns_bridge.start requires identity_path even when identity_bytes is
        // supplied (the bytes win; the path is a fallback). Co-locate it in the
        // shared config dir (the app also writes identity.bin there).
        let identityPath = (configDir as NSString).appendingPathComponent("identity.bin")
        // The `block_unknown_senders` privacy toggle lives in the app's standard
        // UserDefaults (unreachable from the NE), so the app mirrors it into the
        // AppGroup suite (`block_unknown_senders`). The NE passes it to Python so
        // inbound from unknown senders is dropped BEFORE the NE persists the row
        // (the app can't drop a row it never sees).
        let blockUnknownSenders = UserDefaults(suiteName: appGroupIdentifier)?
            .bool(forKey: "block_unknown_senders") ?? false
        let kwargs: [String: Any] = [
            "config_dir": configDir,
            "identity_path": identityPath,
            "display_name": displayName,
            "identity_bytes": Self.b64Wrapper(identity),
            "block_unknown_senders": blockUnknownSenders,
            "host_persistence": "ne",
        ]
        attemptedStart = true
        guard let payload = Self.payload(kwargs: kwargs),
              let out = PythonNodeRuntime.shared.callBridge("start", payload: payload) else {
            ExtensionDiagLog.log("[NE-PY-RNS] start: bridge call failed to build/dispatch")
            return nil
        }
        guard let (ok, result, error) = Self.parse(out) else {
            ExtensionDiagLog.log("[NE-PY-RNS] start: unparseable bridge reply")
            return nil
        }
        if !ok {
            ExtensionDiagLog.log("[NE-PY-RNS] start failed: \(error ?? "(no error)")")
            return nil
        }
        stateLock.lock(); isRunning = true; stateLock.unlock()
        ExtensionDiagLog.log("[NE-PY-RNS] start OK: \(result ?? "")")
        // Restore the saved relay before recovering sends, including when iOS
        // relaunches the extension while the app is suspended.
        if let config = PropagationSeamConfig.loadFromAppGroup(), let hash = config.propagationNodeHash {
            _ = call("set_propagation_node", kwargs: ["dest_hash_hex": hash.map { String(format: "%02x", $0) }.joined(), "stamp_cost": config.stampCost])
        }
        // P1 #3: recover stranded sends. On a fresh (re)start, once the node is
        // up, replay the durable outbox through the deduped send path (gated to a
        // real start so a transiently-failing entry is not re-attempted on every
        // idempotent re-start). P1 #4: arm the bounded outbox retry so a transient
        // or persistent send failure is re-attempted on a cadence while the node
        // stays up, instead of waiting for the next start. The retry self-terminates
        // when the outbox empties or the node stops (no perpetual tick).
        if restarting {
            replayOutbox()
        }
        armReplayRetry()
        if restarting { armPropagationSync() }
        started = true
        return result
    }

    /// Arm the bounded outbox-retry loop (P1 #4). One task, started only while the
    /// node is up; it re-runs `replayOutbox()` every `replayRetryInterval` while the
    /// outbox still has entries, and stops itself the moment the queue drains or the
    /// node stops. Idempotent: a re-start cancels any prior task before arming a new
    /// one, so retry loops never stack. Safe to run alongside live sends because the
    /// retry is a single sequential task (one pass at a time) and `lxmfSend` dedups
    /// on `sendId` under the file lock.
    private func armReplayRetry() {
        stateLock.lock()
        guard isRunning else { stateLock.unlock(); return }
        replayRetryTask?.cancel()
        replayRetryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.stateLock.lock()
                let running = self.isRunning
                self.stateLock.unlock()
                if !running { return }
                guard !self.outboxReplay.pendingReplays().isEmpty else { return }
                self.replayOutbox()
                self.stateLock.lock()
                let stillUp = self.isRunning
                self.stateLock.unlock()
                if !stillUp || self.outboxReplay.pendingReplays().isEmpty { return }
                try? await Task.sleep(nanoseconds: Self.replayRetryIntervalNs)
            }
        }
        stateLock.unlock()
    }

    /// The node owns retrieval in both hosts. In the extension this continues
    /// while the UI is suspended; a foreground node resumes when its app does.
    /// Re-read the seam each pass so relay/interval/enable edits need no restart.
    private func armPropagationSync() {
        propagationSyncTask?.cancel()
        propagationSyncTask = Task.detached { [weak self] in
            var schedule = NodePropagationSchedule()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard let self else { return }
                self.performScheduledPropagationSync(schedule: &schedule)
            }
        }
    }

    private func performScheduledPropagationSync(schedule: inout NodePropagationSchedule) {
        // Serialize with stop/start. A cancelled old worker must never touch a
        // new node, even if it was waiting for this lock during a restart.
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !Task.isCancelled, isRunning else { return }
        let config = PropagationSeamConfig.loadFromAppGroup()
        guard schedule.shouldSync(config: config, now: Date()) else { return }
        // Selection commands own the live relay. Reapplying the persisted
        // snapshot here can undo a clear/change whose persistence is pending.
        _ = propagationSync(timeout: 20.0)
    }

    /// Manual and scheduled retrieval share success publication. The history
    /// lives in the App Group so a suspended or cold-started UI can catch up.
    func propagationSync(timeout: TimeInterval) -> String? {
        let result = call("propagation_sync", kwargs: ["timeout": timeout])
        PropagationSyncStateSnapshot.publishSuccessfulResult(Self.dict(from: result))
        return result
    }

    @discardableResult
    func stop() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard PythonNodeRuntime.shared.state == .running else { return !isRunning }
        guard let reply = PythonNodeRuntime.shared.callBridge("stop", payload: Self.payload(kwargs: [:]) ?? "{}"), Self.parse(reply)?.ok == true else {
            ExtensionDiagLog.log("[RNS-HOST] stop failed; retaining process ownership")
            return false
        }
        stateLock.lock()
        isRunning = false
        replayRetryTask?.cancel()
        replayRetryTask = nil
        propagationSyncTask?.cancel()
        propagationSyncTask = nil
        stateLock.unlock()
        processLease.release()
        ExtensionDiagLog.log("[NE-PY-RNS] stop")
        return true
    }

    /// Foreground-mode owner only: drop the lease flock before iOS suspends
    /// the app. iOS SIGKILLs (0xdead10cc) any process suspended while holding
    /// a file lock in the App Group container, and suspension freezes the
    /// node's threads anyway, so the lock protects nothing across it.
    ///
    /// Deliberately does NOT take `lifecycleLock`: the reporter's kill
    /// happened with a startup in flight holding that lock, so releasing the
    /// lease must work exactly then. `NodeProcessLease` serializes itself.
    func releaseLeaseForBackground() {
        processLease.releaseForBackground()
    }

    /// Re-take the lease after returning from suspension. Returns false when
    /// a live node could not reclaim ownership. While foreground mode is the
    /// selected host the extension re-checks hosting before initializing its
    /// own node, so contention here should be impossible; the caller logs and
    /// keeps the node rather than tearing a working session down.
    func reacquireLeaseAfterForeground() -> Bool {
        stateLock.lock()
        let running = isRunning
        stateLock.unlock()
        guard running else {
            // No live node: only clear the refusal flag so a later start()
            // can acquire normally.
            return processLease.resumeFromBackground(reacquireAt: nil)
        }
        guard let root = AppGroupPaths.containerURL() else { return false }
        return processLease.resumeFromBackground(
            reacquireAt: root.appendingPathComponent("rns-owner.lock"))
    }

    // MARK: - Bridge op wrappers (used by PacketTunnelProvider.dispatchPython)

    /// `rns_bridge.announce(display_name)` → `{ok, reason}`.
    func announce(displayName: String) -> [String: Any]? {
        Self.dict(from: call("announce", kwargs: ["display_name": displayName]))
    }

    /// `rns_bridge.announce_telephony(display_name)` → `{ok, reason}`.
    func announceTelephony(displayName: String) -> [String: Any]? {
        Self.dict(from: call("announce_telephony", kwargs: ["display_name": displayName]))
    }

    /// `rns_bridge.status()` → the snake_case status snapshot JSON the app decodes.
    /// Returns the raw result JSON string (forwarded directly to the IPC).
    func status() -> String? {
        call("status", kwargs: [:])
    }

    /// `rns_bridge.local_info()` → `{identity_hash, destination_hash}`.
    func localInfo() -> String? {
        call("local_info", kwargs: [:])
    }

    /// `rns_bridge.drain_events()` → `[{kind, ...}, ...]`. Non-announce events are
    /// dropped by the caller; returning nil here means the bridge call failed.
    func drainEvents() -> [[String: Any]]? {
        guard let json = call("drain_events", kwargs: [:]),
              let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return arr
    }

    /// `rns_bridge.ack_inbox(max_seq)` - advance the durable-inbox consumer
    /// cursor (Contract §5). The app calls this after it has processed a drained
    /// batch, passing the highest `seq` in that batch; the NE deletes only rows
    /// at or below the cursor. Return true only after Python commits. A failure
    /// leaves the page replayable and the app retries with a delay.
    func ackInbox(maxSeq: Int) -> Bool {
        call("ack_inbox", kwargs: ["max_seq": maxSeq]) == "true"
    }

    /// `rns_bridge.persist()` → `{ok, ...}`.
    func persist() -> [String: Any]? {
        Self.dict(from: call("persist", kwargs: [:]))
    }

    /// `rns_bridge.add_interface(name)` → `{ok, reason}`. Hot-attach an interface
    /// to the live NE node without a restart (RNS 1.5.5). The app has already
    /// rewritten the shared App-Group config, so the NE re-reads the fresh
    /// `[[name]]` section. Returns nil if the bridge call itself failed (vs.
    /// `{"ok": false, "reason": ...}` which means the attach was rejected).
    func attachInterface(name: String) -> [String: Any]? {
        Self.dict(from: call("add_interface", kwargs: ["name": name]))
    }

    /// `rns_bridge.remove_interface(name)` → `{ok, reason}`. Hot-detach an
    /// interface from the live NE node without a restart (RNS 1.5.5, which tears
    /// the interface's spawned children down too). Returns nil if the bridge call
    /// itself failed.
    func detachInterface(name: String) -> [String: Any]? {
        Self.dict(from: call("remove_interface", kwargs: ["name": name]))
    }

    /// Send one outbound LXMF message through the Python engine, with
    /// send-response-ambiguity dedup (P1 #6). If `sendId` is already recorded in
    /// `sentIds`, the send was already delivered (a lost live reply led the app to
    /// re-queue the same id) - skip it and return a "committed" dict so the caller
    /// treats it as sent. Otherwise send and, on a committed (`ok`) result, record
    /// the id so a later drain/restart does not send it again.
    func lxmfSend(destHashHex: String, content: String, method: String, fieldsHex: String, sendId: String? = nil, failureFallbackMethod: String? = nil) -> [String: Any]? {
        if let sendId, outboxReplay.sentIds.contains(sendId) {
            ExtensionDiagLog.log("[NE-PY-RNS] lxmfSend: sendId already sent, dedup skip")
            return ["ok": true, "deduped": true, "message_hash": ""]
        }
        var res = Self.dict(from: call("send_opportunistic", kwargs: [
            "dest_hash_hex": destHashHex,
            "content": content,
            "method": method,
            "fields_hex": fieldsHex,
            "failure_fallback_method": failureFallbackMethod ?? "",
        ]))
        // Log every send outcome (success AND the failure reason) so the send
        // path is observable in ext-diag.log. Previously only dedup-skip and a
        // persist-warning were logged, so a plain send or a "requesting-path" /
        // "not-started" failure left zero trace and was indistinguishable from
        // "never called".
        if let res {
            let reason = res["reason"] as? String ?? (res["ok"] as? Bool == true ? "sent" : "unknown")
            let ok = res["ok"] as? Bool ?? false
            ExtensionDiagLog.log("[NE-PY-RNS] lxmfSend dest=\(String(destHashHex.prefix(8))) method=\(method) sendId=\(sendId ?? "nil") ok=\(ok) reason=\(reason)")
        } else {
            ExtensionDiagLog.log("[NE-PY-RNS] lxmfSend dest=\(String(destHashHex.prefix(8))) method=\(method) sendId=\(sendId ?? "nil") ok=false reason=python-returned-nil")
        }
        if let sendId, res?["ok"] as? Bool == true {
            // P1 #5: a send that committed but whose id could NOT be persisted
            // degrades the lost-reply double-send guard - the next drain/restart
            // would find no saved id and re-send this message. We do NOT flip the
            // send result to failure (the message actually went out; reporting
            // failure would make the app re-enqueue it and double-send, which is
            // strictly worse). Instead we surface it: mark the result so the send
            // path / operators can see the guard is degraded, and log loudly.
            let persisted = outboxReplay.markSent(sendId)
            if !persisted {
                ExtensionDiagLog.log("[NE-PY-RNS] lxmfSend WARNING: sendId committed but NOT persisted to the sent-id store - lost-reply double-send guard is degraded for this send (id=\(sendId))")
                res?["id_persisted"] = false
            }
        }
        return res
    }

    /// Replay any durable outbox entries through the (deduped) send path. Called
    /// once at the end of `start()`, after the Python node is fully up (P1 #3:
    /// stranded sends). Each entry is sent with its stable `sendId`; the dedup
    /// check means a send already recorded (from a live attempt whose reply was
    /// lost) is NOT re-sent, so replay is idempotent. A nil-id entry (pre-migration)
    /// is always sent.
    func replayOutbox() {
        let pending = outboxReplay.pendingReplays()
        guard !pending.isEmpty else { return }
        ExtensionDiagLog.log("[NE-PY-RNS] replaying \(pending.count) outbox entr\(pending.count == 1 ? "y" : "ies")")
        // Issue 1: legacy (nil-sendId) entries have no store id to prune against,
        // so we cannot let commitSent() dedup them via the sent-id store. Instead
        // we track the EXACT entry objects we confirmed sent and remove those
        // specifically below. A legacy entry that fails is NOT added here, so it
        // stays on disk for the next pass; but unlike a sendId'd entry it is also
        // never removed by the id check, so without this explicit tracking the new
        // 5s retry loop would re-send a successfully-sent legacy entry forever.
        var sentLegacyKeys = Set<String>()
        for entry in pending {
            let fieldsHex = entry.fieldsData.map { data in
                data.map { String(format: "%02x", $0) }.joined()
            } ?? ""
            let res = lxmfSend(destHashHex: entry.destHashHex, content: entry.content, method: entry.method, fieldsHex: fieldsHex, sendId: entry.sendId, failureFallbackMethod: entry.failureFallbackMethod)
            if let res, res["ok"] as? Bool == true {
                if entry.sendId == nil {
                    sentLegacyKeys.insert(entry.legacyKey)
                }
                ExtensionDiagLog.log("[NE-PY-RNS] outbox replay ok (id=\(entry.sendId ?? "nil"))")
            } else {
                ExtensionDiagLog.log("[NE-PY-RNS] outbox replay failed (id=\(entry.sendId ?? "nil")): \(res?["reason"] as? String ?? "no reason"))")
            }
        }
        // Durability (P1 #3): the drain above was NON-destructive, so every entry
        // is still on disk. Prune only the ones now confirmed sent (their ids are
        // in the store for sendId'd entries; the explicit legacyKey set for the
        // nil-id ones). The failed / not-yet-reached ones STAY for the next
        // replay or start. This is what makes a mid-loop stop safe: entries the
        // loop never reached are never dropped, and a transient send failure is
        // retried on the next pass instead of waiting for a restart.
        outboxReplay.commitSent(legacyKeys: sentLegacyKeys)
    }

    /// One-shot NomadNet page fetch over an RNS Link (Model B IPC path).
    ///
    /// Marshals into `rns_bridge.nomadnet_fetch_op`, which runs the synchronous
    /// fetch and base64-encodes the `data` bytes (the `callBridge` reply is a
    /// `json.dumps` of the Python return, which can't carry raw bytes). Returns
    /// the parsed Python result dict `{ok, status, data_b64, content_type}`, or
    /// nil on a bridge-level failure. `formFields` nil = plain GET (the op
    /// defaults to `None`). This call blocks up to ~2·timeout inside Python, but
    /// runs on a detached `Task` in `dispatchPython` (not the tunnel thread), so
    /// it does not stall the NE's packet path.
    func nomadnetFetch(destHashHex: String, path: String, timeout: Double, formFields: [String: String]?) -> [String: Any]? {
        var kwargs: [String: Any] = [
            "dest_hash_hex": destHashHex,
            "path": path,
            "timeout": timeout,
        ]
        if let formFields, !formFields.isEmpty {
            kwargs["form_fields"] = formFields
        }
        return Self.dict(from: call("nomadnet_fetch_op", kwargs: kwargs))
    }

    // MARK: - LXST telephony link ops
    //
    // The NE Python RNS owns the live RNS.Link for voice. These mirror the
    // existing `rns_bridge.open_link` / `link_send` / `link_identify` /
    // `link_teardown` functions. Inbound frames + the identify / close events
    // ride the `drainEvents` queue (the `link_*` events), so the app only
    // marshals the four request ops across the seam. `openLink` blocks up to
    // ~10s (the Python bounded path request) but runs on a detached `Task` in
    // `dispatchPython`, so it does not stall the NE's packet path.

    /// `rns_bridge.open_link(dest_hash_hex, aspect, identity_public_key_hex)`
    /// → `{ok, link_id, reason}`. The forward path is the exact shape the app's
    /// `openLink` proxy decodes.
    func openLink(destHashHex: String, aspect: String, identityPublicKeyHex: String) -> [String: Any]? {
        Self.dict(from: call("open_link", kwargs: [
            "dest_hash_hex": destHashHex,
            "aspect": aspect,
            "identity_public_key_hex": identityPublicKeyHex,
        ]))
    }

    /// `rns_bridge.link_send(link_id, data_hex)` → `{ok, reason}`.
    func linkSend(linkId: Int, dataHex: String) -> [String: Any]? {
        Self.dict(from: call("link_send", kwargs: [
            "link_id": linkId,
            "data_hex": dataHex,
        ]))
    }

    /// `rns_bridge.link_identify(link_id)` → `{ok, reason}`.
    func linkIdentify(linkId: Int) -> [String: Any]? {
        Self.dict(from: call("link_identify", kwargs: ["link_id": linkId]))
    }

    /// `rns_bridge.link_teardown(link_id)` → `{ok, reason}`.
    func linkTeardown(linkId: Int) -> [String: Any]? {
        Self.dict(from: call("link_teardown", kwargs: ["link_id": linkId]))
    }

    // MARK: - Ops

    /// Call a `rns_bridge` op that returns a JSON dict, forwarding the raw JSON.
    /// Returns the Python result JSON string, or nil on a bridge-level failure.
    func call(_ fn: String, kwargs: [String: Any]) -> String? {
        guard PythonNodeRuntime.shared.state == .running else {
            #if DEBUG
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): state is \(PythonNodeRuntime.shared.state), not .running")
            #endif
            return nil
        }
        guard let payload = Self.payload(kwargs: kwargs) else {
            #if DEBUG
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): payload construction returned nil")
            #endif
            return nil
        }
        guard let out = PythonNodeRuntime.shared.callBridge(fn, payload: payload) else {
            #if DEBUG
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): callBridge returned nil")
            #endif
            return nil
        }
        guard let (ok, result, error) = Self.parse(out) else {
            #if DEBUG
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): unparseable reply: \(out.prefix(200))")
            #endif
            return nil
        }
        if !ok {
            #if DEBUG
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn) failed: \(Self.shortError(error))")
            #endif
            return nil
        }
        return result
    }

    /// Collapse a Python error (which may be a full `EXC at exec: ...` traceback
    /// containing on-device container source paths) into a short, path-free failure
    /// description for the debug log. The ext-diag.log contract forbids device
    /// container paths, so a traceback is reduced to its final exception line (the
    /// type + message - container paths live only in the `File "..."` frames above
    /// it), and anything else is truncated. (P1 #7: the previous debug branch
    /// logged the raw `format_exc()` including Python source paths.)
    static func shortError(_ error: String?) -> String {
        guard let error, !error.isEmpty else { return "(no error)" }
        let lines = error.split(separator: "\n").map(String.init)
        if let last = lines.last(where: { !$0.isEmpty }) {
            return String(last.trimmingCharacters(in: .whitespaces).prefix(200))
        }
        return String(error.prefix(200))
    }

    /// Fire-and-forget call into a named rns_bridge function (BLE event
    /// delivery). The caller (NEBLECABIBridge) only needs the side effect
    /// (the driver's callback slot firing); the return value is ignored. Logs
    /// failures so a missing slot or a Python-side raise is visible in
    /// ext-diag without tearing down the forwarder.
    func invoke(_ fn: String, kwargs: [String: Any]) {
        guard PythonNodeRuntime.shared.state == .running else {
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): python not running, dropping")
            return
        }
        guard let payload = Self.payload(kwargs: kwargs),
              let out = PythonNodeRuntime.shared.callBridge(fn, payload: payload) else {
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): callBridge returned nil")
            return
        }
        guard let (ok, _, error) = Self.parse(out) else {
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn): unparseable reply")
            return
        }
        if !ok {
            ExtensionDiagLog.log("[NE-PY-RNS] \(fn) raised: \(Self.shortError(error))")
        }
    }

    // MARK: - Shared config dir (NE-side)

    /// The App-Group-shared RNS config dir for the app's current identity.
    /// The app writes `<dir>/config` (+ `identity.bin`) here; the NE reads it.
    /// Returns a tmp fallback when the App-Group container is unavailable
    /// (unsigned build) so `start` degrades instead of crashing.
    static func sharedConfigDir() -> String {
        // Resolve the identity hash from the shared keychain blob so we key the
        // dir the same way the app does (python-<rawIdentityHashHex>). We compute
        // the RNS identity hash in Python (RNS.Identity.from_bytes(...).hash) to
        // avoid importing RNSAPI - but that requires a Python call. Cheaper: the
        // app also persists the raw hex it used, under App-Group defaults.
        if let hex = UserDefaults(suiteName: appGroupIdentifier)?
            .string(forKey: "rnsConfigIdentityHashHex"), !hex.isEmpty {
            if let url = AppGroupPaths.rnsConfigDirectoryURL(identityHashHex: hex) {
                return url.path
            }
        }
        // Fallback: a shared, identity-agnostic dir the app also writes when it
        // can't key per-identity. (Rare - only when the hex default is absent.)
        if let container = AppGroupPaths.containerURL() {
            let dir = container.appendingPathComponent("Columba", isDirectory: true)
                .appendingPathComponent("python-current", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
        // No App-Group container at all (unsigned): tmp fallback.
        return NSTemporaryDirectory()
    }

    // MARK: - JSON helpers

    /// Wrap raw bytes as the `{"__b64__": ...}` marker the Python `_dec` decodes
    /// back to `bytes`.
    private static func b64Wrapper(_ data: Data) -> [String: String] {
        ["__b64__": data.base64EncodedString()]
    }

    /// Build the `{"args":[], "kwargs":{...}}` payload JSON for `callBridge`.
    private static func payload(args: [Any] = [], kwargs: [String: Any]) -> String? {
        let obj: [String: Any] = ["args": args, "kwargs": kwargs]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Parse the `{"ok":.., "result"|"error":..}` reply. `result` is itself a
    /// JSON string (the op's JSON-serializable return).
    private static func parse(_ out: String) -> (ok: Bool, result: String?, error: String?)? {
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let ok = obj["ok"] as? Bool ?? false
        return (ok, obj["result"] as? String, obj["error"] as? String)
    }

    /// Parse a `call` result (the op's JSON-serializable return) into a dict, or
    /// nil when it isn't a JSON object (or the call returned nil).
    private static func dict(from result: String?) -> [String: Any]? {
        guard let result,
              let data = result.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return obj
    }
}
