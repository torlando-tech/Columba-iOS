import Foundation
import RNSAPI

/// Python-backed `RnsBackend` (Android `:rns-backend-py` analog). Wraps
/// `PythonBridge` (the raw CPython embedding) and adapts its Python-flavored raw
/// results onto the neutral RNSAPI DTOs the host (`AppServices`) consumes. The
/// mapping IS this layer's job — `PythonBridge` stays Python-specific; the
/// neutral vocabulary lives in RNSAPI so the UI never sees a Python type.
///
/// - `start(...)` boots Reticulum + LXMRouter under embedded CPython.
/// - `sendOpportunistic` posts opportunistic LXMF via `LXMF.LXMRouter`.
/// - `events` yields announce / inbound / delivery / link events drained from
///   Python every 200ms (mapped to `BackendEvent`); first subscription starts
///   the drain.
@available(iOS 17.0, macOS 14.0, *)
public final class PythonRNSBackend: RnsBackend, @unchecked Sendable {

    private let bridge = PythonBridge()
    private var eventDrainTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<BackendEvent>.Continuation?

    public private(set) var localInfo: LocalInfo?

    /// Stream of backend events. First subscription implicitly starts the drain.
    public lazy var events: AsyncStream<BackendEvent> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
            self.startDrainLoop()
            continuation.onTermination = { _ in
                self.eventDrainTask?.cancel()
                self.eventDrainTask = nil
            }
        }
    }()

    /// What the iOS Python backend can do. Notably: interface hot-reload IS
    /// supported here (unlike Android's Chaquopy python), but telemetry /
    /// location sharing are not yet implemented (the genuine gap the UI gates).
    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            backendId: .pythonEmbedded,
            versions: .init(reticulum: "1.3.1", lxmf: "0.9.9", lxst: nil, bleReticulum: "0.2.2"),
            interfaces: .init(hotReloadInterfaces: true),
            telemetry: .init(
                collectorHostMode: .unsupported,
                storeOwnTelemetry: .unsupported,
                allowedRequestersFilter: .unsupported,
                degradationHint: "Location sharing & telemetry are not yet implemented on the iOS Python backend."
            ),
            performance: .init(batteryProfileTuning: .unsupported, sharedInstanceAvailabilityChecks: false)
        )
    }

    public init() {}

    @discardableResult
    public func start(_ params: StartParams) async throws -> LocalInfo {
        let info = try await bridge.start(
            configDir: params.configDir,
            identityPath: params.identityPath,
            displayName: params.displayName,
            identityBytes: params.identityBytes
        )
        let mapped = LocalInfo(identityHash: info.identityHash, destinationHash: info.destinationHash)
        self.localInfo = mapped
        _ = self.events  // ensure drain loop running even with no subscriber
        return mapped
    }

    public func stop() async {
        eventDrainTask?.cancel()
        eventDrainTask = nil
        do { try await bridge.stop() } catch {}
        localInfo = nil
    }

    public func sendOpportunistic(destHashHex: String, content: String) async throws -> SendOutcome {
        Self.map(try await bridge.sendOpportunistic(destHashHex: destHashHex, content: content))
    }

    /// Set / clear the outbound LXMF propagation node. Empty `destHashHex` clears.
    @discardableResult
    public func setPropagationNode(destHashHex: String, stampCost: Int = 0) async throws -> Bool {
        try await bridge.setPropagationNode(destHashHex: destHashHex, stampCost: stampCost)
    }

    /// Block until the configured propagation-node sync completes.
    public func propagationSync(timeout: TimeInterval = 60.0) async throws -> PropagationSyncResult {
        Self.map(try await bridge.propagationSync(timeout: timeout))
    }

    /// Push a fresh LXMF delivery announce (Settings Announce button + auto-announce timer).
    @discardableResult
    public func announce(displayName: String) async throws -> Bool {
        try await bridge.announce(displayName: displayName)
    }

    /// Push a fresh LXST telephony announce — peers learn our voice-call destination.
    @discardableResult
    public func announceTelephony(displayName: String) async throws -> Bool {
        try await bridge.announceTelephony(displayName: displayName)
    }

    // MARK: - RNS.Link operations (voice / future Link-based protocols)
    //
    // The Swift LXST state machine (lxst-swift Telephone actor) drives these.
    // Python is just the underlying Link pipe — frames marshalled over via
    // openLink + linkSend + linkPacket events.

    public func openLink(destHashHex: String, aspect: String = "lxst.telephony") async throws -> (ok: Bool, linkId: Int, reason: String) {
        try await bridge.openLink(destHashHex: destHashHex, aspect: aspect)
    }

    @discardableResult
    public func linkSend(linkId: Int, data: Data) async throws -> Bool {
        try await bridge.linkSend(linkId: linkId, data: data)
    }

    @discardableResult
    public func linkIdentify(linkId: Int) async throws -> Bool {
        try await bridge.linkIdentify(linkId: linkId)
    }

    @discardableResult
    public func linkTeardown(linkId: Int) async throws -> Bool {
        try await bridge.linkTeardown(linkId: linkId)
    }

    /// One-shot NomadNet page fetch.
    public func fetchNomadNetPage(
        destHashHex: String,
        path: String,
        timeout: TimeInterval = 30.0,
        formFields: [String: String]? = nil
    ) async throws -> NomadNetFetchResult {
        Self.map(try await bridge.fetchNomadNetPage(
            destHashHex: destHashHex,
            path: path,
            timeout: timeout,
            formFields: formFields
        ))
    }

    /// Single-shot RNS Transport status probe (interfaces, online flags, table sizes).
    public func statusSnapshot() async -> StatusSnapshot? {
        guard let s = await bridge.status() else { return nil }
        return Self.map(s)
    }

    /// Force RNS to flush its path table + known destinations to disk. RNS only
    /// persists on a 12h timer / clean exit, which iOS skips — call on background.
    @discardableResult
    public func persist() async -> Bool {
        await bridge.callModuleFunctionNoArgs(name: "persist")
    }

    // MARK: - Live interface reconfiguration (no restart)

    @discardableResult
    public func addInterface(name: String) async throws -> (ok: Bool, reason: String) {
        try await bridge.applyInterface(name: name, add: true)
    }

    @discardableResult
    public func removeInterface(name: String) async throws -> (ok: Bool, reason: String) {
        try await bridge.applyInterface(name: name, add: false)
    }

    // MARK: - Python-backend-specific extras (NOT part of RnsBackend)
    //
    // These reach the raw bridge for Python-only wiring (BLE/RNode callback
    // bridges, smoke-test hooks). AppServices uses them only on Python-specific
    // paths, downcasting from `any RnsBackend` where needed.

    /// Direct access for the BLE/RNode callback bridges + stamp generator install.
    public var pythonBridge: PythonBridge { bridge }

    @discardableResult
    public func installBLETestRoundtripCallback() async -> Bool {
        await bridge.callModuleFunctionNoArgs(name: "_install_test_roundtrip_callback")
    }

    public func invokeBLETestRoundtrip(value: Int) -> Bool {
        bridge.invokeBLECallbackBoolSync(slot: "_test_roundtrip", args: [.int(value)])
    }

    // MARK: - Event drain + raw→neutral mapping

    private func startDrainLoop() {
        guard eventDrainTask == nil else { return }
        eventDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let events = await self.bridge.drainEvents()
                for event in events {
                    self.eventContinuation?.yield(Self.map(event))
                }
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
    }

    private static func map(_ e: PythonBridge.Event) -> BackendEvent {
        switch e {
        case let .announce(d, a, asp, pk, ifn, h, t):
            return .announce(destHash: d, appDataHex: a, aspect: asp, publicKeysHex: pk, interfaceName: ifn, hops: h, t: t)
        case let .inbound(s, c, ti, t):
            return .inbound(sourceHash: s, content: c, title: ti, t: t)
        case let .state(s, t):
            return .state(s, t: t)
        case let .delivery(m, s, t):
            return .delivery(messageHash: m, state: s, t: t)
        case let .linkState(l, s, r, i, t):
            return .linkState(linkId: l, state: s, reason: r, inbound: i, t: t)
        case let .linkPacket(l, dat, t):
            return .linkPacket(linkId: l, data: dat, t: t)
        case let .linkIdentified(l, idh, t):
            return .linkIdentified(linkId: l, identityHashHex: idh, t: t)
        }
    }

    private static func map(_ o: PythonBridge.SendOutcome) -> SendOutcome {
        switch o {
        case let .queued(h): return .queued(messageHash: h)
        case .requestingPath: return .requestingPath
        case .badHash: return .badHash
        case .notStarted: return .notStarted
        case let .other(s): return .other(s)
        }
    }

    private static func map(_ r: PythonBridge.PropagationSyncResult) -> PropagationSyncResult {
        PropagationSyncResult(
            ok: r.ok,
            state: PropagationSyncResult.State(rawValue: r.state.rawValue) ?? .unknown,
            receivedMessages: r.receivedMessages,
            reason: r.reason
        )
    }

    private static func map(_ r: PythonBridge.NomadNetFetchResult) -> NomadNetFetchResult {
        NomadNetFetchResult(
            ok: r.ok,
            status: NomadNetFetchResult.Status(rawValue: r.status.rawValue) ?? .unknown,
            data: r.data,
            contentType: r.contentType
        )
    }

    private static func map(_ s: PythonBridge.StatusSnapshot) -> StatusSnapshot {
        StatusSnapshot(
            started: s.started,
            interfaces: s.interfaces.map {
                StatusSnapshot.InterfaceStatus(
                    sectionName: $0.sectionName, name: $0.name, online: $0.online,
                    rxBytes: $0.rxBytes, txBytes: $0.txBytes
                )
            },
            destinationTableSize: s.destinationTableSize,
            pathTableSize: s.pathTableSize
        )
    }
}
