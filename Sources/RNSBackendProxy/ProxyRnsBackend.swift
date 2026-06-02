//
//  ProxyRnsBackend.swift
//  Columba (RNSBackendProxy — compiled into ColumbaApp)
//
//  Track A5b — the app-side thin client for the Model B send path.
//
//  Under Model B the Network Extension owns the canonical `lxmf.delivery`
//  destination + node (A5a's `NEReticulumNode`). The app therefore must NOT run
//  its own destination-owning backend — instead `BackendFactory` hands the app
//  this `ProxyRnsBackend`, which conforms to the full `RnsBackend` protocol but
//  *marshals* node-owning operations to the NE over IPC (`ProxyIPC` envelopes
//  sent through an injected async send closure) rather than touching a local
//  reticulum-swift / LXMF-swift stack.
//
//  ── ALWAYS-THE-NODE INVARIANT ────────────────────────────────────────────────
//  This type owns NO destination, identity, transport, or router. When Model B
//  is enabled the NE is the single owner of the `lxmf.delivery` destination; if
//  the app also started a `SwiftRNSBackend`/`PythonRNSBackend` they would BOTH
//  register the same destination and double-deliver. `BackendFactory` enforces
//  this by returning EITHER a destination-owning backend OR this proxy, never
//  both (see `BackendFactory.make()`).
//
//  ── COLLISION RULE (HARD) ────────────────────────────────────────────────────
//  This file imports RNSAPI ONLY (for the `RnsBackend` protocol surface +
//  `StartParams` / `LocalInfo` / `SendOutcome` / `StatusSnapshot` / `BackendEvent`
//  / `LXDeliveryMethod` / `RnsFileAttachment` / `IconAppearance`). It MUST NOT
//  import ReticulumSwift or LXMFSwift: it only marshals already-serialized data
//  across the seam (hex strings, MessagePack-packed field bytes via RNSAPI's
//  `LxmfFieldCodec`, JSON), and never constructs a protocol object
//  (Identity/Destination/Link/LXMessage/…). `ProxyIPC` itself is Foundation-only
//  (Shared target).
//

import Foundation
import os
import RNSAPI

/// Errors raised by the Model B proxy for operations that are NOT marshaled to
/// the NE (they run NE-side under the in-extension node, or aren't part of the
/// A5b skeleton yet).
public enum BackendError: Error, LocalizedError, Equatable {
    /// The called method has no app-side meaning under Model B: it operates on
    /// node-owned state that lives entirely in the NE and isn't proxied (yet).
    /// `feature` names the method for diagnostics.
    case unsupportedInProxy(feature: String)
    /// The IPC round-trip itself failed (no response / undecodable response) —
    /// distinct from the NE answering `.unsupported`/`.error`.
    case ipcFailed(operation: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInProxy(let feature):
            return "Unsupported in Model B proxy: \(feature)"
        case .ipcFailed(let operation):
            return "Model B IPC failed: \(operation)"
        }
    }
}

/// App-side `RnsBackend` that proxies node-owning operations to the NE under
/// Model B. Conforms to the FULL protocol; only the key node ops marshal, the
/// rest throw `BackendError.unsupportedInProxy` or no-op (each annotated).
///
/// `@unchecked Sendable`: the only mutable state is `cachedLocalInfo`, guarded by
/// `stateLock` (never held across an `await`), matching `SwiftRNSBackend`'s
/// class-with-lock posture.
@available(iOS 17.0, macOS 14.0, *)
public final class ProxyRnsBackend: RnsBackend, @unchecked Sendable {

    private static let log = Logger(subsystem: "network.columba.Columba", category: "ProxyRnsBackend")

    /// Injected IPC transport: encode-send-receive a single request/response.
    /// Decoupled from `TunnelManager` (which wraps `sendProviderMessage`'s
    /// completion handler in a continuation) so the proxy is testable with a
    /// stub closure. Returns the raw response `Data` (the NE's encoded
    /// `ProxyResponse`), or `nil` on a transport-level failure.
    private let send: @Sendable (Data) async -> Data?

    /// Last `LocalInfo` learned from a `.start` response. The protocol's
    /// `localInfo` is synchronous (`get`-only), so cache the async-fetched value
    /// here. Guarded by `stateLock`.
    private var cachedLocalInfo: LocalInfo?
    private let stateLock = NSLock()

    /// The neutral event stream. Under Model B the NE owns inbound delivery and
    /// notifies the app via the App-Group store + Darwin notification (A5a), NOT
    /// via this stream — so the stream is intentionally inert here (no events are
    /// yielded). It exists only to satisfy `RnsCore.events`; A5c/the live wiring
    /// can later bridge NE-pushed events onto `eventContinuation`.
    private let eventStream: AsyncStream<BackendEvent>
    private let eventContinuation: AsyncStream<BackendEvent>.Continuation

    public init(send: @escaping @Sendable (Data) async -> Data?) {
        self.send = send
        (eventStream, eventContinuation) = AsyncStream.makeStream()
    }

    // MARK: - IPC helper

    /// Encode + send a request, returning the decoded `ProxyResponse`. Throws
    /// `BackendError.ipcFailed` when the envelope can't be encoded or no/garbled
    /// response comes back; returns the `ProxyResponse` (including `.error` /
    /// `.unsupported`) otherwise so callers can map those onto their own return
    /// shapes.
    private func roundTrip(_ request: ProxyRequest, op: String) async throws -> ProxyResponse {
        let wire: Data
        do {
            wire = try ProxyIPC.encodeRequest(request)
        } catch {
            throw BackendError.ipcFailed(operation: op)
        }
        let reply = await send(wire)
        guard let response = ProxyIPC.decodeResponse(reply) else {
            throw BackendError.ipcFailed(operation: op)
        }
        return response
    }

    // MARK: - RnsCore

    public var localInfo: LocalInfo? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedLocalInfo
    }

    public var events: AsyncStream<BackendEvent> { eventStream }

    @discardableResult
    public func start(_ params: StartParams) async throws -> LocalInfo {
        // The NE loads the shared identity + computes the App-Group store path
        // itself (A5a); only the display name needs to cross the seam.
        let response = try await roundTrip(.start(displayName: params.displayName), op: "start")
        switch response {
        case .ok(let payload):
            guard let payload,
                  let info = try? JSONDecoder().decode(ProxyLocalInfo.self, from: payload) else {
                throw BackendError.ipcFailed(operation: "start")
            }
            let local = LocalInfo(identityHash: info.identityHash, destinationHash: info.destinationHash)
            stateLock.lock(); cachedLocalInfo = local; stateLock.unlock()
            return local
        case .error(let message):
            throw RNSError.generic(message: message, stackTraceText: nil)
        case .unsupported:
            // NE node not running (e.g. shared identity not yet created).
            throw RNSError.backendNotReady
        }
    }

    public func stop() async {
        _ = try? await roundTrip(.stop, op: "stop")
        stateLock.lock(); cachedLocalInfo = nil; stateLock.unlock()
    }

    @discardableResult
    public func announce(displayName: String) async throws -> Bool {
        try await marshalBool(.announce(displayName: displayName), op: "announce")
    }

    @discardableResult
    public func announceTelephony(displayName: String) async throws -> Bool {
        try await marshalBool(.announceTelephony(displayName: displayName), op: "announceTelephony")
    }

    public func statusSnapshot() async -> StatusSnapshot? {
        // Best-effort: a failed round-trip / unsupported reply yields nil (same
        // contract as the other backends when the stack isn't up).
        guard let response = try? await roundTrip(.statusSnapshot, op: "statusSnapshot"),
              case .ok(let payload) = response, let payload else {
            return nil
        }
        return try? JSONDecoder().decode(StatusSnapshot.self, from: payload)
    }

    @discardableResult
    public func persist() async -> Bool {
        guard let response = try? await roundTrip(.persist, op: "persist") else { return false }
        if case .ok = response { return true }
        return false
    }

    public func registeredDestinationHashes() async -> [String] {
        guard let response = try? await roundTrip(.registeredDestinationHashes, op: "registeredDestinationHashes"),
              case .ok(let payload) = response, let payload,
              let hashes = try? JSONDecoder().decode([String].self, from: payload) else {
            return []
        }
        return hashes
    }

    // MARK: - RnsLxmf

    @discardableResult
    public func sendLxmfMessage(
        destHashHex: String,
        content: String,
        method: LXDeliveryMethod,
        imageData: Data?,
        imageFormat: String?,
        fileAttachments: [RnsFileAttachment]?,
        iconAppearance: IconAppearance?,
        replyToMessageHashHex: String?,
        replyQuotedContent: String?,
        extraFields: [UInt8: Data]?
    ) async throws -> SendOutcome {
        // Assemble the canonical on-wire LXMF field map APP-SIDE (RNSAPI's
        // `LxmfFieldCodec` is in scope here; the NE-side dispatch is NOT — it
        // doesn't import RNSAPI) and pass it across the seam as MessagePack
        // bytes. The NE rebuilds the `LXMessage` from `(destHashHex, content,
        // method, fieldsData)`.
        let fields = LxmfFieldCodec.buildFieldMap(
            imageData: imageData, imageFormat: imageFormat,
            fileAttachments: fileAttachments, iconAppearance: iconAppearance,
            replyToMessageHashHex: replyToMessageHashHex, replyQuotedContent: replyQuotedContent,
            extraFields: extraFields)
        let fieldsData = fields.isEmpty ? Data() : LxmfFieldCodec.pack(fields)

        let response = try await roundTrip(
            .lxmfSend(destHashHex: destHashHex, content: content, method: method.rawValue, fieldsData: fieldsData),
            op: "lxmfSend")
        switch response {
        case .ok(let payload):
            guard let payload,
                  let outcome = try? JSONDecoder().decode(ProxySendOutcome.self, from: payload) else {
                return .other("malformed send response")
            }
            return Self.sendOutcome(from: outcome)
        case .error(let message):
            return .other(message)
        case .unsupported:
            return .notStarted
        }
    }

    @discardableResult
    public func sendReaction(destHashHex: String, targetMessageHashHex: String, emoji: String) async throws -> SendOutcome {
        // Model B: not proxied yet (would ride the same lxmf-send path NE-side;
        // out of the A5b skeleton). Treat as not-started so the UI degrades like
        // a stopped backend rather than crashing.
        throw BackendError.unsupportedInProxy(feature: "sendReaction")
    }

    @discardableResult
    public func setPropagationNode(destHashHex: String, stampCost: Int) async throws -> Bool {
        // Model B: runs NE-side / not proxied yet.
        throw BackendError.unsupportedInProxy(feature: "setPropagationNode")
    }

    public func propagationSync(timeout: TimeInterval) async throws -> PropagationSyncResult {
        // Model B: runs NE-side / not proxied yet.
        PropagationSyncResult(ok: false, state: .noNode, receivedMessages: 0, reason: "not proxied (Model B)")
    }

    // MARK: - RnsTelemetry

    @discardableResult
    public func sendLocationTelemetry(destHashHex: String, packed: Data, customMeta: Data?) async throws -> SendOutcome {
        // Model B: not proxied yet (would route via the NE lxmf-send path with
        // FIELD_TELEMETRY 0x02; out of the A5b skeleton).
        throw BackendError.unsupportedInProxy(feature: "sendLocationTelemetry")
    }

    // Collector-host mode is honest-unsupported on the Swift stack too — no-op
    // returning false here (Model B: runs NE-side / not proxied yet).
    public func setTelemetryCollectorMode(enabled: Bool) async -> Bool { false }
    public func storeOwnTelemetry(packed: Data) async -> Bool { false }
    public func setTelemetryAllowedRequesters(_ allowedHashesHex: Set<String>) async -> Bool { false }

    // MARK: - RnsNomadnet

    public func fetchNomadNetPage(
        destHashHex: String,
        path: String,
        timeout: TimeInterval,
        formFields: [String: String]?
    ) async throws -> NomadNetFetchResult {
        // Model B: runs NE-side / not proxied yet.
        NomadNetFetchResult(ok: false, status: .notStarted, data: Data(), contentType: "")
    }

    // MARK: - RnsTelephony
    //
    // Voice links are driven by the in-process LXST state machine and require a
    // live local RNS.Link — they CANNOT be proxied frame-by-frame at acceptable
    // latency, so under Model B telephony stays app-local (out of A5b scope).
    // Each throws so a missed UI capability gate fails loud rather than silently
    // dropping audio. (Model B: runs NE-side / not proxied yet.)

    public func openLink(destHashHex: String, aspect: String) async throws -> (ok: Bool, linkId: Int, reason: String) {
        throw BackendError.unsupportedInProxy(feature: "openLink")
    }

    @discardableResult
    public func linkSend(linkId: Int, data: Data) async throws -> Bool {
        throw BackendError.unsupportedInProxy(feature: "linkSend")
    }

    @discardableResult
    public func linkIdentify(linkId: Int) async throws -> Bool {
        throw BackendError.unsupportedInProxy(feature: "linkIdentify")
    }

    @discardableResult
    public func linkTeardown(linkId: Int) async throws -> Bool {
        throw BackendError.unsupportedInProxy(feature: "linkTeardown")
    }

    // MARK: - RnsTransportAdmin
    //
    // Interfaces are owned by the NE's transport under Model B (the NE binds the
    // radios); live add/remove from the app isn't proxied yet. (Model B: runs
    // NE-side / not proxied yet.)

    @discardableResult
    public func addInterface(name: String) async throws -> (ok: Bool, reason: String) {
        throw BackendError.unsupportedInProxy(feature: "addInterface")
    }

    @discardableResult
    public func removeInterface(name: String) async throws -> (ok: Bool, reason: String) {
        throw BackendError.unsupportedInProxy(feature: "removeInterface")
    }

    // MARK: - Capabilities

    /// Same backend-id as the native stack — under Model B the NE runs
    /// reticulum-swift / LXMF-swift, so versions match `SwiftRNSBackend`. The
    /// proxy declares hot-reload OFF (interface admin isn't proxied) and
    /// telemetry unsupported (not proxied in A5b); refine when A5c wires the
    /// remaining ops.
    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            backendId: .swiftNative,
            versions: .init(reticulum: "0.2.3", lxmf: "0.3.4", lxst: nil, bleReticulum: nil),
            interfaces: .init(hotReloadInterfaces: false),
            telemetry: .init(
                collectorHostMode: .unsupported,
                storeOwnTelemetry: .unsupported,
                allowedRequestersFilter: .unsupported,
                degradationHint: "Model B proxy: telemetry/propagation/telephony/nomadnet/interface-admin are not proxied to the NE yet (A5b skeleton)."
            ),
            performance: .init(batteryProfileTuning: .unsupported, sharedInstanceAvailabilityChecks: false)
        )
    }

    // MARK: - Mapping helpers

    /// Marshal a request whose `.ok` payload is a JSON-encoded `Bool`.
    private func marshalBool(_ request: ProxyRequest, op: String) async throws -> Bool {
        let response = try await roundTrip(request, op: op)
        switch response {
        case .ok(let payload):
            guard let payload, let value = try? JSONDecoder().decode(Bool.self, from: payload) else {
                return false
            }
            return value
        case .error(let message):
            throw RNSError.generic(message: message, stackTraceText: nil)
        case .unsupported:
            throw RNSError.backendNotReady
        }
    }

    private static func sendOutcome(from outcome: ProxySendOutcome) -> SendOutcome {
        switch outcome.kind {
        case .queued:         return .queued(messageHash: outcome.detail ?? "")
        case .requestingPath: return .requestingPath
        case .badHash:        return .badHash
        case .notStarted:     return .notStarted
        case .other:          return .other(outcome.detail ?? "")
        }
    }
}
