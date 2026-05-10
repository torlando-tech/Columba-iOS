//
//  TestController.swift
//  ColumbaApp
//
//  Debug-only test surface for the columba-iOS phone harness.
//
//  Mirror of `app/src/debug/java/network/columba/app/test/TestController.kt`
//  on the Android side. Lazy-initialized on the first URL action received
//  by [TestURLHandler]. Binds to the live `AppServices` (router, interface
//  repository) supplied at injection time, then subscribes to the inbound
//  message and delivery-status callbacks. Each handler logs a structured
//  `event=… key=value` line via `os_log` under the dedicated
//  `network.columba.app.test` subsystem so `idevicesyslog` can filter
//  cleanly.
//
//  This file lives under `Sources/ColumbaApp/Test/` and the entire
//  contents are wrapped in `#if DEBUG`, so it never compiles into a
//  Release `.ipa`. Defense in depth: every entry point also calls
//  `assertionFailure("must not run in release")` (debug-build assertion
//  which is a no-op in release-config — but we never get here in a
//  release config because the file is fully ifdef'd out).
//

#if DEBUG

import Foundation
import os.log
import OSLog
import LXMFSwift

// MARK: - Logging

/// Dedicated subsystem for the test harness. The original design called
/// for `idevicesyslog` to filter by (process, subsystem, category) for
/// real-time tailing, but iOS 17+ moved the syslog stream behind the new
/// CoreDevice / RemoteXPC protocol that libimobiledevice can't speak,
/// and `pymobiledevice3` requires a developer-tunnel daemon to bridge it.
/// Rather than maintain that fragile pairing, the orchestrator now polls
/// a structured file at `Documents/test_log.txt` (pulled via
/// `xcrun devicectl device copy from --domain-type appDataContainer`).
/// `os_log` writes are kept as-is for human / Console.app readers; the
/// file is the contract the harness consumes.
public enum TestLog {
    public static let subsystem = "network.columba.app.test"
    public static let category = "harness"
    public static let logger = Logger(subsystem: subsystem, category: category)

    /// Per-launch monotonically-increasing line number, so a harness that
    /// pulls the log file mid-run can detect "did any new lines arrive
    /// since the last poll" without relying on file-size deltas (which
    /// can race with append-writes mid-flight).
    private static var sequence: UInt64 = 0
    private static let sequenceLock = NSLock()

    /// File-descriptor cache. Opened lazily, kept open for the app
    /// lifetime so each emit() is a write+fsync, not an open+write+close.
    private static var fileHandle: FileHandle?
    private static let handleLock = NSLock()

    /// Resolved path to the log file inside the app's sandbox Documents
    /// dir. Computed once on first use.
    public static let logFilePath: String = {
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
        ).first ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent("test_log.txt")
    }()

    /// All harness output goes through this single sink so the Python
    /// orchestrator's regex sees one consistent shape.
    ///
    /// Emits to BOTH:
    ///   - `os_log` for live Console.app / Xcode console viewing
    ///   - `Documents/test_log.txt` (newline-terminated) for the
    ///     orchestrator's `devicectl copy from`-based poller
    ///
    /// Each line is prefixed `seq=<n> ts=<iso8601> ` so the harness can
    /// detect new lines after a poll and reason about ordering.
    public static func emit(_ line: String) {
        os_log("%{public}@", log: OSLog(subsystem: subsystem, category: category),
               type: .info, line)

        sequenceLock.lock()
        sequence &+= 1
        let seq = sequence
        sequenceLock.unlock()

        let ts = ISO8601DateFormatter().string(from: Date())
        let prefixed = "seq=\(seq) ts=\(ts) \(line)\n"

        handleLock.lock()
        defer { handleLock.unlock() }
        if fileHandle == nil {
            let path = logFilePath
            // Truncate on first write of each app launch so the harness
            // doesn't have to reason about cross-launch line numbers.
            // The file is bounded by the harness's own retry-cap anyway.
            FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
            fileHandle = FileHandle(forWritingAtPath: path)
        }
        if let fh = fileHandle, let data = prefixed.data(using: .utf8) {
            try? fh.write(contentsOf: data)
            // Don't fsync per write — it'd serialize all emit() calls and
            // wreck the log under bursty events. The harness polls every
            // ~250ms; OS page-cache flush easily keeps up.
        }
    }
}

// MARK: - Whitespace escape (matches the Android TestController exactly)

/// Escape any whitespace so the value is always a single `\S+` token in
/// the harness's `key=value` format. Mirrors the Android side's
/// `escape()` helper byte-for-byte.
///
///   ' ' (0x20)  → '␣' (U+2423 OPEN BOX)
///   '\n' (0x0A) → '⏎' (U+23CE RETURN SYMBOL)
///   '\r' (0x0D) → '␍' (U+240D SYMBOL FOR CARRIAGE RETURN)
///   '\t' (0x09) → '␉' (U+2409 SYMBOL FOR HORIZONTAL TABULATION)
///
/// Caps the escaped output at 1024 chars so a runaway message body can't
/// blow up the log line size. Long values are truncated with a trailing
/// `…` sentinel.
public func testHarnessEscape(_ s: String) -> String {
    var out = s.replacingOccurrences(of: " ", with: "\u{2423}")
    out = out.replacingOccurrences(of: "\n", with: "\u{23CE}")
    out = out.replacingOccurrences(of: "\r", with: "\u{240D}")
    out = out.replacingOccurrences(of: "\t", with: "\u{2409}")
    if out.count > 1024 {
        out = String(out.prefix(1024)) + "…"
    }
    return out
}

// MARK: - Hex helpers

private func toHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func fromHex(_ s: String) -> Data? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count % 2 == 0 else { return nil }
    var out = Data()
    out.reserveCapacity(trimmed.count / 2)
    var i = trimmed.startIndex
    while i < trimmed.endIndex {
        let next = trimmed.index(i, offsetBy: 2)
        guard let byte = UInt8(trimmed[i..<next], radix: 16) else { return nil }
        out.append(byte)
        i = next
    }
    return out
}

// MARK: - TestController

/// Singleton coordinating the harness's test-action surface.
///
/// On first use, [TestURLHandler] calls [bind] with a reference to the
/// live `AppServices` actor; subsequent actions invoke the typed handlers
/// below, which interact with the router / interface repository and emit
/// `event=key=value` lines through [TestLog].
@MainActor
public final class TestController {
    public static let shared = TestController()

    private var appServices: AnyObject?
    /// `LXMRouter` reference, captured at bind time so we don't have to
    /// reach through AppServices on every call. The router is a class
    /// (reference type) and pinned by AppServices for the app's lifetime.
    private var routerRef: LXMRouter?
    /// `InterfaceRepository` reference, captured at bind time. Same
    /// rationale as `routerRef`.
    private var interfaceRepoRef: InterfaceRepository?

    /// Local LXMF destination hash (16 bytes). Captured at bind time,
    /// returned by `get_dest`. The Android side calls
    /// `protocol.getLxmfDestination()` per action; on iOS the hash is
    /// stable for the app's lifetime so we cache it.
    private var destHashCached: Data?

    /// In-process inbound queue; the harness drains via `get_rx`.
    private var rxQueue: [TestRxRecord] = []

    /// Per-message hash → string-form delivery state. Mirrors the Android
    /// side's `deliveryStates` map.
    private var deliveryStates: [String: String] = [:]

    /// Set true once [bind] has registered the receive observer.
    private var initialized = false

    /// Strong reference to our installed delegate. LXMRouter holds the
    /// delegate weakly (LXMRouter.swift `weak var delegate`), so without
    /// this anchor the relay deallocates immediately after attachDelegate
    /// returns, the router's reference goes nil, and didUpdateMessage
    /// never fires for outbound state transitions. Symptom: smoke runs
    /// where lxmd accepts the message (`Proof confirmed delivery`) but
    /// the harness never sees `state=PROPAGATED` because the .sent
    /// transition never reaches the test surface.
    private var attachedDelegate: LXMRouterDelegate?

    private init() {}

    // MARK: - Init / bind

    /// Bind to the live AppServices instance and register receive +
    /// delivery-status observers. Idempotent — repeat calls re-bind
    /// against the new AppServices (a no-op for the production code path,
    /// but useful in tests where AppServices is reconstructed).
    public func bind(
        appServices: AnyObject,
        router: LXMRouter,
        interfaceRepo: InterfaceRepository,
        destHash: Data
    ) {
        assertionFailure_releaseGuard()
        self.appServices = appServices
        self.routerRef = router
        self.interfaceRepoRef = interfaceRepo
        self.destHashCached = destHash
        if !initialized {
            // Install harness-side LXMRouterDelegate observer. The app's
            // primary delegate is `IncomingMessageHandler`; we don't want
            // to displace it, so we register a TestRelayDelegate that
            // forwards to the original delegate AND records into our rx
            // queue + delivery state map. Wired by TestURLHandler at
            // bind time (see `attachDelegate()`).
            initialized = true
            TestLog.emit("controller_ready")
        } else {
            TestLog.emit("controller_rebound")
        }
    }

    /// Attach the harness's relay delegate, preserving the original.
    /// Called by [TestURLHandler] right after `bind` to wire in
    /// observation of received messages + delivery state changes.
    public func attachDelegate(to router: LXMRouter, originalDelegate: LXMRouterDelegate?) async {
        let relay = TestRelayDelegate(
            wrapped: originalDelegate,
            controller: self
        )
        // Pin the relay to TestController BEFORE handing it to the router.
        // Router holds the delegate weakly; without this strong reference
        // the relay deallocates as soon as this function returns.
        attachedDelegate = relay
        await router.setDelegate(relay)
    }

    /// Append an inbound message to the rx queue. Called by
    /// [TestRelayDelegate] on the main actor.
    fileprivate func recordReceived(_ message: LXMessage) {
        let rec = TestRxRecord(
            sourceHash: toHex(message.sourceHash),
            messageHash: toHex(message.hash),
            content: String(data: message.content, encoding: .utf8) ?? "<binary>"
        )
        rxQueue.append(rec)
        TestLog.emit(
            "rx_msg source=stream from=\(rec.sourceHash) " +
            "id=\(rec.messageHash) content=\(testHarnessEscape(rec.content))"
        )
    }

    /// Record a delivery-state transition. Called by
    /// [TestRelayDelegate] on the main actor.
    fileprivate func recordDeliveryState(messageHash: Data, state: String) {
        let idHex = toHex(messageHash)
        deliveryStates[idHex] = state
        TestLog.emit("msg_state id=\(idHex) state=\(state)")
    }

    // MARK: - Action handlers (mirror TestController.kt)

    public func handleGetDest() {
        assertionFailure_releaseGuard()
        guard initialized, let hash = destHashCached else {
            TestLog.emit("dest_err reason=not_ready")
            return
        }
        TestLog.emit("dest=\(toHex(hash))")
    }

    public func handleHasPath(toHex hex: String) {
        assertionFailure_releaseGuard()
        guard initialized else {
            TestLog.emit("has_path to=\(hex) result=err msg=not_ready")
            return
        }
        guard let toBytes = fromHex(hex) else {
            TestLog.emit("has_path to=\(hex) result=err_bad_hex")
            return
        }
        // ReticulumSwift's PathTable lookup is async. Run on the same
        // actor; emit the result line when done.
        Task {
            let has = await checkPath(to: toBytes)
            TestLog.emit("has_path to=\(hex) result=\(has ? 1 : 0)")
        }
    }

    private func checkPath(to: Data) async -> Bool {
        // Walk through AppServices.pathTable. We hold AppServices via
        // `appServices` (AnyObject) to avoid a hard import dependency
        // here; resolve via the typed bridge in TestURLHandler.
        guard let bridge = TestPathBridge.hasPath else { return false }
        return await bridge(to)
    }

    public func handleSend(method: LXDeliveryMethod, toHex hex: String, text: String) {
        assertionFailure_releaseGuard()
        guard initialized, let router = routerRef else {
            TestLog.emit("msg_send_err method=\(methodName(method)) reason=not_ready")
            return
        }
        guard let toBytes = fromHex(hex) else {
            TestLog.emit("msg_send_err method=\(methodName(method)) reason=bad_hex to=\(hex)")
            return
        }
        Task {
            do {
                let messageHash = try await TestPathBridge.send?(toBytes, text, method)
                if let h = messageHash {
                    let idHex = toHex(h)
                    TestLog.emit("msg_sent id=\(idHex) method=\(methodName(method)) to=\(hex)")
                    if deliveryStates[idHex] == nil {
                        deliveryStates[idHex] = "OUTBOUND"
                    }
                } else {
                    TestLog.emit("msg_send_err method=\(methodName(method)) to=\(hex) reason=no_send_bridge")
                }
            } catch {
                TestLog.emit(
                    "msg_send_err method=\(methodName(method)) to=\(hex) " +
                    "reason=\(testHarnessEscape(error.localizedDescription))"
                )
            }
            _ = router  // silence unused warning when send path is bridged
        }
    }

    public func handleGetMsgState(idHex: String) {
        assertionFailure_releaseGuard()
        let state = deliveryStates[idHex] ?? "UNKNOWN"
        TestLog.emit("msg_state id=\(idHex) state=\(state)")
    }

    public func handleGetRx() {
        assertionFailure_releaseGuard()
        let drained = rxQueue
        rxQueue.removeAll(keepingCapacity: false)
        for rec in drained {
            TestLog.emit(
                "rx_msg source=drain from=\(rec.sourceHash) " +
                "id=\(rec.messageHash) content=\(testHarnessEscape(rec.content))"
            )
        }
        TestLog.emit("rx_drain count=\(drained.count)")
    }

    public func handleRxClear() {
        assertionFailure_releaseGuard()
        rxQueue.removeAll(keepingCapacity: false)
        TestLog.emit("rx_cleared")
    }

    public func handleAnnounce() {
        assertionFailure_releaseGuard()
        guard initialized, let hash = destHashCached else {
            TestLog.emit("announce_err reason=no_active_destination")
            return
        }
        Task {
            do {
                try await TestPathBridge.announce?()
                TestLog.emit("announced dest=\(toHex(hash))")
            } catch {
                TestLog.emit(
                    "announce_err dest=\(toHex(hash)) " +
                    "reason=\(testHarnessEscape(error.localizedDescription))"
                )
            }
        }
    }

    /// Dump the iOS unified log for the LXMF/propagation subsystems
    /// into test_log.txt so the harness can see what's happening
    /// inside the library on failure. iOS 17+ moved live syslog behind
    /// the developer tunnel (libimobiledevice/idevicesyslog can't
    /// reach it) so we pull from OSLogStore in-process and forward
    /// each entry as a `lib_log` event line.
    ///
    /// Filtered to the subsystems we know LXMFSwift / ColumbaApp use:
    ///   - com.columba.core (propLogger, syncLogger, routerLogger)
    ///   - net.reticulum.lxmf (default routerLogger in LXMRouter.swift)
    public func handleDumpLog(
        sinceSeconds: Double = 120.0,
        categoryFilter: String? = nil
    ) {
        assertionFailure_releaseGuard()
        Task {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let cutoff = store.position(date: Date().addingTimeInterval(-sinceSeconds))
                // Stream entries WITHOUT a predicate (NSPredicate against
                // OSLogStore doesn't support category-level filtering on all
                // OS versions; do it in-loop for portability) and filter by
                // (subsystem, category) ourselves. Default: only the
                // LXMFSwift propagation/sync/router categories that matter
                // for the bug we're chasing.
                let entries = try store.getEntries(at: cutoff)
                let allowedSubsystems: Set<String> = [
                    "com.columba.core",
                    "net.reticulum.lxmf",
                    "net.reticulum",       // Link, Transport, Packet routing
                    "network.columba.Columba",  // app-side managers
                ]
                let allowedCategoriesDefault: Set<String> = [
                    "Propagation", "Sync", "LXMRouter", "Stamper", "Identity",
                    "PropagationNodeManager",
                    "Link",                // ← Link state machine + processProof
                    "Transport",           // packet dispatch / routing
                    "Packet",
                ]
                let allowedCategories: Set<String>? = categoryFilter
                    .map { Set($0.split(separator: ",").map(String.init)) }
                var count = 0
                for entry in entries {
                    guard let logEntry = entry as? OSLogEntryLog else { continue }
                    let subsys = logEntry.subsystem
                    let cat = logEntry.category
                    if !allowedSubsystems.contains(subsys) { continue }
                    if let allowed = allowedCategories,
                       !allowed.contains(cat) { continue }
                    if allowedCategories == nil,
                       !allowedCategoriesDefault.contains(cat) { continue }
                    let level = String(describing: logEntry.level)
                    let msg = testHarnessEscape(logEntry.composedMessage)
                    // Emit the entry's ACTUAL OS-recorded timestamp as
                    // an extra `entry_ts=` field. The seq=N ts=... prefix
                    // emitted by TestLog is the dump-time (when this loop
                    // ran), not the log-time, so the harness needs the
                    // entry timestamp to reason about ordering across
                    // events that happened during the smoke run.
                    let entryTs = ISO8601DateFormatter().string(from: logEntry.date)
                    TestLog.emit(
                        "lib_log entry_ts=\(entryTs) subsys=\(subsys) cat=\(cat) " +
                        "level=\(level) msg=\(msg)"
                    )
                    count += 1
                    if count > 500 { break }  // higher cap now that we filter
                }
                TestLog.emit("lib_log_done count=\(count) since_sec=\(Int(sinceSeconds))")
            } catch {
                TestLog.emit(
                    "lib_log_err reason=\(testHarnessEscape(error.localizedDescription))"
                )
            }
        }
    }

    // ─── interface management ──────────────────────────────────────────

    public func handleListInterfaces() {
        assertionFailure_releaseGuard()
        guard let repo = interfaceRepoRef else {
            TestLog.emit("interface_list_done count=0")
            return
        }
        let rows = repo.interfaces
        for e in rows {
            TestLog.emit(
                "interface id=\(e.id) name=\(testHarnessEscape(e.name)) " +
                "type=\(e.type.rawValue) enabled=\(e.enabled)"
            )
        }
        TestLog.emit("interface_list_done count=\(rows.count)")
    }

    public func handleDisableAllInterfaces() {
        assertionFailure_releaseGuard()
        guard let repo = interfaceRepoRef else {
            TestLog.emit("interfaces_disabled count=0 applied=false err=no_repo")
            return
        }
        var disabled = 0
        for e in repo.interfaces where e.enabled {
            repo.toggleInterface(id: e.id, enabled: false)
            disabled += 1
        }
        applyAndLog(event: "interfaces_disabled", extras: "count=\(disabled)")
    }

    public func handleSetInterfaceEnabled(name: String, enabled: Bool) {
        assertionFailure_releaseGuard()
        guard let repo = interfaceRepoRef else {
            TestLog.emit("interface_\(enabled ? "enable" : "disable")_err name=\(testHarnessEscape(name)) reason=no_repo")
            return
        }
        guard let e = repo.interfaces.first(where: { $0.name == name }) else {
            TestLog.emit(
                "interface_\(enabled ? "enable" : "disable")_err " +
                "name=\(testHarnessEscape(name)) reason=not_found"
            )
            return
        }
        repo.toggleInterface(id: e.id, enabled: enabled)
        applyAndLog(
            event: enabled ? "interface_enabled" : "interface_disabled",
            extras: "name=\(testHarnessEscape(name)) id=\(e.id)"
        )
    }

    public func handleAddTcpClient(name: String, host: String, port: Int) {
        assertionFailure_releaseGuard()
        guard let repo = interfaceRepoRef else {
            TestLog.emit("interface_add_err reason=no_repo")
            return
        }
        guard port > 0, port < 65536 else {
            TestLog.emit("interface_add_err reason=bad_port port=\(port)")
            return
        }
        // Replace-on-existing for idempotent re-runs (matches the
        // Android side's delete-then-insert behavior).
        if let existing = repo.interfaces.first(where: { $0.name == name }) {
            repo.deleteInterface(id: existing.id)
        }
        let cfg = TCPClientConfig(targetHost: host, targetPort: UInt16(port))
        let entity = InterfaceEntity(
            name: name,
            type: .tcpClient,
            enabled: true,
            mode: .full,
            config: .tcpClient(cfg)
        )
        repo.addInterface(entity)
        applyAndLog(
            event: "interface_added",
            extras: "name=\(testHarnessEscape(name)) id=\(entity.id) " +
                    "type=TCPClient host=\(testHarnessEscape(host)) port=\(port)"
        )
    }

    public func handleRemoveInterface(name: String) {
        assertionFailure_releaseGuard()
        guard let repo = interfaceRepoRef else {
            TestLog.emit("interface_remove_err name=\(testHarnessEscape(name)) reason=no_repo")
            return
        }
        guard let e = repo.interfaces.first(where: { $0.name == name }) else {
            TestLog.emit("interface_remove_err name=\(testHarnessEscape(name)) reason=not_found")
            return
        }
        repo.deleteInterface(id: e.id)
        applyAndLog(
            event: "interface_removed",
            extras: "name=\(testHarnessEscape(name)) id=\(e.id)"
        )
    }

    public func handleSetPropNode(hex: String) {
        assertionFailure_releaseGuard()
        guard let router = routerRef else {
            TestLog.emit("prop_node_err reason=no_router")
            return
        }
        let bytes = hex.isEmpty ? nil : fromHex(hex)
        if !hex.isEmpty && bytes == nil {
            TestLog.emit("prop_node_err reason=bad_hex hex=\(hex)")
            return
        }
        // Read the bridge on the MainActor (where this method already
        // runs) before hopping into the detached Task. The Task body
        // is non-MainActor and can't observe @MainActor static vars.
        let select = TestPathBridge.selectPropNode
        Task {
            // Prefer the manager so stamp cost gets wired alongside the
            // outbound-node hash. Fall back to the router-level setter
            // only when the bridge isn't populated (defensive — bind()
            // installs it under DEBUG).
            if let bytes = bytes, let select = select {
                await select(bytes)
            } else {
                await router.setOutboundPropagationNode(bytes)
            }
            TestLog.emit("prop_node_set hex=\(bytes == nil ? "(cleared)" : hex)")
        }
    }

    public func handleSyncProp() {
        assertionFailure_releaseGuard()
        guard let router = routerRef else {
            TestLog.emit("prop_sync_err reason=no_router")
            return
        }
        Task {
            do {
                try await router.syncFromPropagationNode()
                TestLog.emit("prop_sync_started state=0 messages_received=0")
            } catch {
                TestLog.emit(
                    "prop_sync_err reason=\(testHarnessEscape(error.localizedDescription))"
                )
            }
        }
    }

    // MARK: - Helpers

    private func methodName(_ m: LXDeliveryMethod) -> String {
        switch m {
        case .opportunistic: return "OPPORTUNISTIC"
        case .direct: return "DIRECT"
        case .propagated: return "PROPAGATED"
        case .paper: return "PAPER"
        @unknown default: return "UNKNOWN"
        }
    }

    /// On iOS there's no separate `interfaceConfigManager.applyChanges()`
    /// step — InterfaceRepository's `saveInterfaces()` already posts a
    /// CFNotificationCenter Darwin notification that the network
    /// extension picks up to apply the diff. So `applied=true` is always
    /// emitted (matching the Android contract); the harness can't
    /// distinguish "applied" vs "saved" here without round-tripping
    /// through the extension, which is out of scope for v1.
    private func applyAndLog(event: String, extras: String) {
        TestLog.emit("\(event) \(extras) applied=true")
    }

    /// Defense-in-depth: this whole file should be excluded from release
    /// via `#if DEBUG`, but if a build-config misconfig somehow includes
    /// it, every entry trips this assertion. `assertionFailure` is
    /// stripped in release-config builds, so a real release-build that
    /// got here would silently no-op rather than crash — which is
    /// exactly why the file ALSO ships under `#if DEBUG` (this assertion
    /// is the inner of two layers).
    /// Defense-in-depth runtime guard: if some build-config or compile-
    /// conditions misconfiguration ever lets this code run in a non-DEBUG
    /// build, crash hard at the first invocation rather than silently
    /// expose the test surface. In normal DEBUG builds this is a no-op.
    ///
    /// (Was previously calling `assertionFailure(...)` unconditionally —
    /// which is exactly the wrong direction. `assertionFailure` ALWAYS
    /// crashes in DEBUG builds, so every test entry-point crashed the app
    /// on the guard before reaching any actual logic. Mirrors the Android
    /// side's `check(BuildConfig.DEBUG)` semantics: throw only when DEBUG
    /// is FALSE.)
    private func assertionFailure_releaseGuard() {
        #if !DEBUG
        fatalError(
            "TestController must not run in release builds — " +
            "this is a debug-only test surface; non-debug invocation " +
            "indicates a build-config or compile-conditions misconfiguration"
        )
        #endif
    }
}

// MARK: - Inbound record

private struct TestRxRecord {
    let sourceHash: String
    let messageHash: String
    let content: String
}

// MARK: - Relay delegate (forwards to original + records into TestController)

/// Forwards every LXMRouterDelegate callback to the wrapped delegate
/// (so the app's normal flow keeps working), AND records the relevant
/// signals into [TestController] for the harness to observe.
@MainActor
private final class TestRelayDelegate: LXMRouterDelegate {
    private let wrapped: LXMRouterDelegate?
    private weak var controller: TestController?

    init(wrapped: LXMRouterDelegate?, controller: TestController) {
        self.wrapped = wrapped
        self.controller = controller
    }

    func router(_ router: LXMRouter, didReceiveMessage message: LXMessage) {
        controller?.recordReceived(message)
        wrapped?.router(router, didReceiveMessage: message)
    }

    func router(_ router: LXMRouter, didUpdateMessage message: LXMessage) {
        let stateName: String
        switch message.state {
        case .generating: stateName = "GENERATING"
        case .outbound: stateName = "OUTBOUND"
        case .sending: stateName = "SENDING"
        case .sent:
            // SENT after a PROPAGATED send means the propagation node
            // accepted the LXMF resource transfer — which is the signal
            // the Android harness's `state=PROPAGATED` matches on. Emit
            // the Android-shaped token so cross-platform regexes hold.
            stateName = (message.method == .propagated)
                ? "PROPAGATED"
                : "SENT"
        case .delivered: stateName = "DELIVERED"
        case .rejected: stateName = "REJECTED"
        case .cancelled: stateName = "CANCELLED"
        case .failed: stateName = "FAILED"
        @unknown default: stateName = "UNKNOWN"
        }
        controller?.recordDeliveryState(messageHash: message.hash, state: stateName)
        wrapped?.router(router, didUpdateMessage: message)
    }

    func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError) {
        controller?.recordDeliveryState(messageHash: message.hash, state: "FAILED")
        wrapped?.router(router, didFailMessage: message, reason: reason)
    }

    func router(_ router: LXMRouter, didConfirmDelivery messageHash: Data) {
        controller?.recordDeliveryState(messageHash: messageHash, state: "DELIVERED")
        wrapped?.router(router, didConfirmDelivery: messageHash)
    }

    func router(_ router: LXMRouter, didUpdateSyncState state: PropagationTransferState) {
        wrapped?.router(router, didUpdateSyncState: state)
    }

    func router(_ router: LXMRouter, didCompleteSyncWithNewMessages newMessages: Int) {
        wrapped?.router(router, didCompleteSyncWithNewMessages: newMessages)
    }
}

// MARK: - Bridge for actions that need AppServices internals

/// Slim bridge so [TestController] can avoid a hard import of
/// `AppServices` (which would otherwise force the whole app object graph
/// into the test surface). [TestURLHandler] populates these closures at
/// bind time.
public enum TestPathBridge {
    /// `(destHash) -> Bool` — does the path table know a route to the
    /// given destination?
    @MainActor public static var hasPath: ((Data) async -> Bool)?

    /// `(destHash, text, method) async throws -> messageHash` — send an
    /// LXMF message via the live router with the requested delivery
    /// method. Returns the canonical message hash on success.
    @MainActor public static var send: ((Data, String, LXDeliveryMethod) async throws -> Data)?

    /// `() async throws -> Void` — force-announce the local LXMF
    /// destination. Maps to AppServices.sendAnnounce(...).
    @MainActor public static var announce: (() async throws -> Void)?

    /// `(hash) async -> Void` — fully select a propagation node by
    /// going through `PropagationNodeManager.selectNode`. That call
    /// pushes BOTH the outbound-node hash AND the announce-derived
    /// stamp cost into the router. Bypassing it via the bare
    /// `router.setOutboundPropagationNode(hash)` leaves the cost at
    /// 0, which makes `LXMRouter.sendPropagated` ship a random stamp
    /// that lxmd then rejects with `ERROR_INVALID_STAMP` (the symptom
    /// observed during the iOS PROPAGATED smoke run on 2026-05-10).
    @MainActor public static var selectPropNode: ((Data) async -> Void)?
}

#endif  // DEBUG
