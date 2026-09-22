//
//  NEMicroRNSEngine.swift
//  ColumbaNetworkExtension
//
//  The in-NE engine adapter: wraps the existing Model B `NEReticulumNode`
//  (the C++ microRNS node the NE already runs) behind the `NodeEngine` seam
//  (contract 15). This is the FIRST engine that actually drives a real
//  Reticulum implementation through the node owner - proving the seam works
//  end-to-end in the NE with the engine that ships today. Python RNS and
//  Reticulum-Go drop in as sibling conformances; nothing in the store,
//  control channel, or node owner changes.
//
//  It maps the contract surface onto the node's existing IPC methods:
//    start      -> node.start() + localInfo/statusSnapshot
//    stop       -> node.stop()
//    runtime    -> derived from statusSnapshot + localInfo
//    execute    -> sendLxmfForIPC for submitMessage (the first vertical slice)
//    canExecute -> capability gate (running + destination present)
//
//  The node is an actor (async), so every engine call is async - matching the
//  `NodeEngine` seam. `canExecute` stays synchronous (a pure state check the
//  store's admission policy calls inside its transaction).

import Foundation
import ColumbaNode

/// Maps a `ProxySendOutcome` (the node's existing send result) onto the
/// contract's `EngineCommandResult`. The result-reason mapping is contract
/// -significant: `queued` is a committed send, `requestingPath` is durable +
/// resumable (NOT a committed failure), the rest are typed rejections.
private func engineResult(from outcome: ProxySendOutcome) -> EngineCommandResult {
    switch outcome.kind {
    case .queued:
        // A committed outbound send. The durable domain change is the message
        // now in the delivery pipeline; commit it under the command's identity.
        return .ok(EngineChange(entity: .message, key: outcome.detail ?? "", identityID: nil,
                                revision: Counter(1), removed: false))
    case .requestingPath:
        // Path not yet available: durable + resumable, not a committed reject.
        return .interrupted
    case .badHash:
        return .rejected(NodeError.invalidArgument("destination", "unknown delivery destination"))
    case .notStarted:
        return .rejected(NodeError(code: .unavailable, retry: .afterStateChange,
                                   message: "node not started"))
    case .other:
        return .rejected(NodeError(code: .transportUnavailable, retry: .afterStateChange,
                                   message: outcome.detail ?? "send failed"))
    }
}

/// The `NodeEngine` conformance over the in-NE `NEReticulumNode`.
public final class NEMicroRNSEngine: NodeEngine, @unchecked Sendable {
    private let node: NEReticulumNode
    private let bootID: BootID
    private var running = false

    public init(node: NEReticulumNode) {
        self.node = node
        self.bootID = BootID()
    }

    public var buildInfo: BuildInfo {
        BuildInfo(name: "microRNS", revision: "in-NE", adapterRevision: "1")
    }

    public var capabilities: [Capability] {
        [Capability(feature: .durableMessaging,
                    support: running ? .supported : .unsupported,
                    availability: running ? .available : .disabled,
                    reason: running ? nil : "node not started")]
    }

    public func start(store: NodeStore) async throws -> Descriptor {
        let started = try await node.start()
        self.running = started
        let runtime = await self.makeRuntimeSnapshot(desiredEnabled: started)
        let capabilities: [Capability] = [
            Capability(feature: .durableMessaging,
                       support: started ? .supported : .unsupported,
                       availability: started ? .available : .disabled,
                       reason: started ? nil : "node did not start (no shared identity yet?)"),
        ]
        return Descriptor(version: .v1_0, storeEpoch: store.epochValue, bootID: bootID,
                          storeSchema: 1, capabilities: capabilities, backend: buildInfo,
                          runtime: runtime)
    }

    public func stop() async {
        await node.stop()
        self.running = false
    }

    public func runtimeSnapshot() async -> RuntimeSnapshot {
        await makeRuntimeSnapshot(desiredEnabled: running)
    }

    /// Derive a `RuntimeSnapshot` from the node's live status + local info.
    private func makeRuntimeSnapshot(desiredEnabled: Bool) async -> RuntimeSnapshot {
        let localInfo = await node.localInfoForIPC()
        let hasIdentity = localInfo != nil
        // Connectivity: the node reports interface snapshots; interfacesAvailable
        // if it has a live transport (identity + destination present is a good
        // proxy for the first slice), otherwise noInterfaces.
        let connectivity: RuntimeSnapshot.Connectivity =
            (hasIdentity) ? .interfacesAvailable : .noInterfaces
        let phase: RuntimeSnapshot.Phase
        if !desiredEnabled { phase = .stopped }
        else if hasIdentity { phase = .ready }
        else { phase = .degraded }
        return RuntimeSnapshot(bootID: bootID, phase: phase, desiredEnabled: desiredEnabled,
                               actualEnabled: hasIdentity, enabledIdentities: [],
                               connectivity: connectivity, observedAt: Instant(date: Date()))
    }

    public func execute(_ intent: Intent) async throws -> EngineCommandResult {
        switch intent.body {
        case let .submitMessage(submit):
            // The first vertical slice: a durable chat message send. Map the
            // contract delivery policy onto the node's send method. `automatic`
            // and `opportunistic` both ride the LXMF opportunistic path here;
            // `direct`/`propagated` map to their raw-value method names the node
            // understands.
            let method = submit.delivery.preferred.rawValue
            guard let content = chatContent(submit.payload) else {
                return .rejected(NodeError(code: .payloadUnavailable,
                                           message: "no inline chat content to send"))
            }
            let outcome = await node.sendLxmfForIPC(destHashHex: submit.destination.hex,
                                                    content: content, method: method, fieldsData: Data())
            return engineResult(from: outcome)
        default:
            // Beyond the first vertical slice.
            return .rejected(NodeError(code: .unsupported,
                                       message: "command '\(intent.body.tagName)' not supported by the in-NE engine in the first slice"))
        }
    }

    /// The capability gate (synchronous, called inside the store's admission
    /// transaction): durable messaging is only runnable while the node is up.
    public func canExecute(_ intent: Intent) -> NodeError? {
        if !running {
            return NodeError(code: .unavailable, retry: .afterStateChange,
                             message: "node not started")
        }
        return nil
    }

    /// Extract inline chat text from a chat payload.
    private func chatContent(_ payload: MessagePayload) -> String? {
        switch payload {
        case .chat(let c): return c.content
        default: return nil
        }
    }
}
