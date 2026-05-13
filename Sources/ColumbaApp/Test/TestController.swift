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
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

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

    /// Periodic screenshot/lifecycle Task. Spawned by `bind()` on first
    /// init; runs for the app's lifetime, snapping the key window every
    /// `screenshotIntervalSec` seconds + emitting a `tick` event with the
    /// current applicationState so we can correlate "URL handler stopped
    /// firing" against "app backgrounded / inactive". Diagnoses the
    /// 2026-05-10 iOS smoke harness wedge where the URL handler stops
    /// answering after a few sequential runs.
    private var diagnosticTickTask: Task<Void, Never>?
    private let screenshotIntervalSec: UInt64 = 2
    private var screenshotSeq: UInt64 = 0
    private static let screenshotsDirName = "screenshots"
    private static let maxScreenshots = 30

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
            startDiagnosticTicker()
            registerLifecycleObservers()
        } else {
            TestLog.emit("controller_rebound")
        }
    }

    // MARK: - Diagnostic ticker (screenshot + lifecycle)
    //
    // The harness wedge surfaces as "lxma-test:// URLs stop reaching the
    // URL handler" — but URL handler dispatch requires the app to be
    // foreground-active, so the natural hypothesis is iOS deactivating /
    // backgrounding the app between runs. Pure log files can't disprove
    // that (URL events stop because the cause stops dispatch). This
    // ticker is driven by an internal Task, NOT URL dispatch — so it
    // keeps emitting even when the URL handler is wedged. If the ticker
    // events also stop, the app is suspended/killed (a stronger signal
    // than wedged-URL-handler alone). If ticks keep coming but
    // `applicationState != .active`, that's the smoking gun: app went
    // to .inactive/.background.

    private func startDiagnosticTicker() {
        #if canImport(UIKit)
        diagnosticTickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.tickOnce()
                try? await Task.sleep(
                    nanoseconds: self.screenshotIntervalSec * 1_000_000_000
                )
            }
        }
        #endif
    }

    #if canImport(UIKit)
    private func tickOnce() async {
        screenshotSeq &+= 1
        let seq = screenshotSeq

        let state = UIApplication.shared.applicationState
        let stateStr: String
        switch state {
        case .active:     stateStr = "active"
        case .inactive:   stateStr = "inactive"
        case .background: stateStr = "background"
        @unknown default: stateStr = "unknown"
        }

        var path: String? = nil
        // Only snap when active — UIWindowScene is foregrounded only
        // when active, and a snapshot from a non-active scene is either
        // empty or stale and would mislead diagnosis.
        if state == .active {
            path = captureKeyWindowSnapshot(seq: seq)
            rotateScreenshots()
        }

        TestLog.emit(
            "diag_tick seq=\(seq) state=\(stateStr) snapshot=\(path ?? "<skip>")"
        )
    }

    /// Capture the current key window's contents as a PNG into
    /// `Documents/screenshots/<seq>.png`. Returns the on-device path on
    /// success.
    private func captureKeyWindowSnapshot(seq: UInt64) -> String? {
        let scenes = UIApplication.shared.connectedScenes
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return nil
        }
        guard let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            return nil
        }

        let bounds = window.bounds
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard let png = image.pngData() else { return nil }

        let dir = Self.screenshotsDir()
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        let filename = String(format: "diag-%06llu.png", seq)
        let path = (dir as NSString).appendingPathComponent(filename)
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            return nil
        }
    }

    private func rotateScreenshots() {
        let dir = Self.screenshotsDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let pngs = entries
            .filter { $0.hasSuffix(".png") }
            .sorted()
        guard pngs.count > Self.maxScreenshots else { return }
        for old in pngs.prefix(pngs.count - Self.maxScreenshots) {
            let p = (dir as NSString).appendingPathComponent(old)
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    private static func screenshotsDir() -> String {
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
        ).first ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent(screenshotsDirName)
    }

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification,  "did_become_active"),
            (UIApplication.willResignActiveNotification, "will_resign_active"),
            (UIApplication.didEnterBackgroundNotification, "did_enter_background"),
            (UIApplication.willEnterForegroundNotification, "will_enter_foreground"),
            (UIApplication.willTerminateNotification, "will_terminate"),
        ]
        for (name, label) in pairs {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                TestLog.emit("lifecycle event=\(label)")
            }
        }
    }
    #else
    private func registerLifecycleObservers() {}
    #endif

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

    /// Dump the full LXMF DB conversation list and per-conversation
    /// message metadata into the test log. Used to diagnose user-
    /// observed UI grouping bugs ("PROP messages appear in a separate
    /// conversation from DIRECT/OPP", "no inbound PROP visible") where
    /// the answer depends on what the DB actually has — the iOS UI
    /// faithfully renders whatever the conversations + messages tables
    /// contain, so DB-level inspection is the source of truth.
    ///
    /// Output shape (one line each):
    ///   conv hash=<32hex> display=<name> last_ts=<ts> unread=<n>
    ///   msg conv=<32hex> id=<32hex> dir=<in|out> method=<int> state=<int> ts=<ts> from=<32hex> to=<32hex>
    ///
    /// `method` and `state` are raw `LXDeliveryMethod` /
    /// `LXMessageState` enum values — the harness or a human reader
    /// translates via the LXMF source. Per-conversation message dump
    /// is capped at 50 most-recent rows.
    public func handleDumpDb() {
        assertionFailure_releaseGuard()
        guard let appServices = self.appServices as? AppServices,
              let database = appServices.database else {
            TestLog.emit("dump_db_err reason=no_db")
            return
        }
        Task {
            do {
                let conversations = try await database.getConversations(limit: 1000, offset: 0)
                TestLog.emit("dump_db_begin convs=\(conversations.count)")
                for conv in conversations {
                    let hashHex = conv.destinationHash.map { String(format: "%02x", $0) }.joined()
                    let nameStr = (conv.displayName ?? "").isEmpty
                        ? "<no_name>"
                        : testHarnessEscape(conv.displayName ?? "")
                    TestLog.emit(
                        "conv hash=\(hashHex) "
                        + "display=\(nameStr) "
                        + "last_ts=\(conv.lastMessageTimestamp) "
                        + "unread=\(conv.unreadCount)"
                    )
                    let records = try await database.getMessageRecords(
                        forConversation: conv.destinationHash,
                        limit: 50, offset: 0
                    )
                    for r in records {
                        let convHex = r.conversationHash.map { String(format: "%02x", $0) }.joined()
                        let idHex = (r.messageId ?? Data()).map { String(format: "%02x", $0) }.joined()
                        let srcHex = r.sourceHash.map { String(format: "%02x", $0) }.joined()
                        let dstHex = r.destinationHash.map { String(format: "%02x", $0) }.joined()
                        let dir = r.incoming ? "in" : "out"
                        TestLog.emit(
                            "msg conv=\(convHex) "
                            + "id=\(idHex) "
                            + "dir=\(dir) "
                            + "method=\(r.method) "
                            + "state=\(r.state) "
                            + "ts=\(r.timestamp) "
                            + "from=\(srcHex) "
                            + "to=\(dstHex)"
                        )
                    }
                }
                TestLog.emit("dump_db_done")
            } catch {
                TestLog.emit(
                    "dump_db_err reason=\(testHarnessEscape(error.localizedDescription))"
                )
            }
        }
    }

    /// Query the iOS notification center for delivered notifications.
    /// Emits one `notif` line per delivered notification, including its
    /// `delivery_ts` (ISO8601 seconds), `thread`, `id`, and a
    /// length-limited preview of the body. Used by the Phase 3
    /// `suspended_notification` smoke scenario to prove whether a
    /// system-level notification was posted while the app was
    /// suspended (delivery_ts < foreground_ts → notification fired
    /// during suspension; otherwise it only fired on resume or not
    /// at all).
    ///
    /// `UNUserNotificationCenter.deliveredNotifications` is iOS-only;
    /// this handler is a no-op on macOS-Catalyst builds (which don't
    /// participate in the phone smoke pipeline anyway).
    public func handleGetNotifications() {
        assertionFailure_releaseGuard()
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        Task {
            let notifs = await UNUserNotificationCenter.current().deliveredNotifications()
            TestLog.emit("notif_begin count=\(notifs.count) query_ts=\(Self.iso8601Now())")
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for n in notifs {
                let id = testHarnessEscape(n.request.identifier)
                let thread = testHarnessEscape(n.request.content.threadIdentifier)
                let title = testHarnessEscape(n.request.content.title)
                let bodyRaw = n.request.content.body
                // Cap preview at 80 chars so a malicious sender can't
                // inflate the log line beyond `os_log` truncation.
                let bodyPreview = bodyRaw.count > 80
                    ? String(bodyRaw.prefix(80)) + "…"
                    : bodyRaw
                let body = testHarnessEscape(bodyPreview)
                let ts = iso.string(from: n.date)
                let sourceHash = (n.request.content.userInfo["sourceHash"] as? String) ?? ""
                TestLog.emit(
                    "notif id=\(id) thread=\(thread) title=\(title) "
                    + "delivery_ts=\(ts) source_hash=\(sourceHash) "
                    + "body=\(body)"
                )
            }
            TestLog.emit("notif_end count=\(notifs.count)")
        }
        #else
        TestLog.emit("notif_unsupported platform=non_ios")
        #endif
    }

    /// ISO8601 timestamp of `Date()` with fractional seconds, used by
    /// `handleGetNotifications` to stamp the query time so the smoke
    /// orchestrator can compare `delivery_ts < query_ts` to determine
    /// whether the notification was posted before or after the
    /// foregrounding that triggered the query.
    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Emit current iOS notification authorization status + Columba's
    /// own `notifications_enabled` UserDefaults pref. Used by the
    /// suspended_notification smoke scenario to detect "permission
    /// not granted" up-front rather than diagnose from a 0/0
    /// suspended/post_foreground count ambiguously.
    ///
    /// Emits a single line:
    /// `notif_status auth=<status> alert=<int> badge=<int> sound=<int> notifications_enabled=<bool>`
    /// where `auth` is one of: `notDetermined`, `denied`,
    /// `authorized`, `provisional`, `ephemeral`, `unknown`.
    public func handleGetNotifStatus() {
        assertionFailure_releaseGuard()
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let authStr: String
            switch settings.authorizationStatus {
            case .notDetermined: authStr = "notDetermined"
            case .denied:        authStr = "denied"
            case .authorized:    authStr = "authorized"
            case .provisional:   authStr = "provisional"
            case .ephemeral:     authStr = "ephemeral"
            @unknown default:    authStr = "unknown"
            }
            let alert = settings.alertSetting == .enabled ? 1 : 0
            let badge = settings.badgeSetting == .enabled ? 1 : 0
            let sound = settings.soundSetting == .enabled ? 1 : 0
            let notifEnabled = UserDefaults.standard.object(forKey: "notifications_enabled") as? Bool ?? false
            TestLog.emit(
                "notif_status auth=\(authStr) alert=\(alert) "
                + "badge=\(badge) sound=\(sound) "
                + "notifications_enabled=\(notifEnabled)"
            )
        }
        #else
        TestLog.emit("notif_status_unsupported platform=non_ios")
        #endif
    }

    /// Request iOS notification permission (`UNUserNotificationCenter
    /// .requestAuthorization`) AND set Columba's `notifications_enabled`
    /// UserDefaults pref to `true`. Used by the `suspended_notification`
    /// smoke scenario to bootstrap permission state on first run.
    ///
    /// On a phone that has NEVER seen the request prompt for Columba,
    /// iOS will display the system "Allow notifications?" UI. The
    /// orchestrator can't tap "Allow" automatically (no system-UI
    /// interaction permitted from `xcrun devicectl`), so the first run
    /// after a fresh install requires Tyler to tap Allow manually.
    /// Subsequent runs reuse the persisted grant.
    ///
    /// Emits: `notif_request granted=<bool> error=<msg|nil>`.
    public func handleRequestNotifPermission() {
        assertionFailure_releaseGuard()
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        // Set Columba's own pref true up-front; UN auth is the gate
        // we can't bypass from code, but the pref check at
        // NotificationService.postMessageNotification line 166 also
        // has to pass.
        UserDefaults.standard.set(true, forKey: "notifications_enabled")
        UserDefaults.standard.set(true, forKey: "notify_received_message")
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                TestLog.emit("notif_request granted=\(granted) error=nil")
            } catch {
                TestLog.emit("notif_request granted=false error=\(testHarnessEscape(error.localizedDescription))")
            }
        }
        #else
        TestLog.emit("notif_request_unsupported platform=non_ios")
        #endif
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
