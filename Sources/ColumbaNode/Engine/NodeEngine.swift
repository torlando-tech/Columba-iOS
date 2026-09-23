//
//  NodeEngine.swift
//  ColumbaNode
//
//  The engine-adapter seam (contract 15, ADR 0001). `NodeEngine` is the ONLY
//  surface the node owner (NE) uses to reach a Reticulum implementation. The
//  facade/store/control-channel never touch the engine directly - they talk to
//  the node owner, which decides whether an admitted command can actually run
//  and drives the engine.
//
//  This is what makes the three preferred implementations interchangeable:
//    1. Python RNS  (official reference; the first engine, embedded CPython in the NE)
//    2. Reticulum-Go (https://github.com/Quad4-Software/Reticulum-Go)
//    3. microReticulum (the C++ engine the existing Model B NE already runs)
//  Each is a `NodeEngine` conformance; the store, command ledger, canonical
//  digest, and control framing are all shared and engine-independent.
//
//  Deliberately minimal: the engine is a black box that (a) reports its
//  descriptor/capabilities, (b) executes an admitted command, (c) streams node
//  changes into the shared store, and (d) stops. It does NOT re-derive app
//  behavior, allocate a second node, or redefine the durable records
//  (contract 15 / ADR 0001: engine choice is behind the adapter and must never
//  redefine app behavior).
//

import Foundation

/// The node's lifecycle phase as reported by an engine (mirrors
/// `RuntimeSnapshot.Phase`; an engine may be finer-grained internally but maps
/// onto this for the control channel).
public typealias NodePhase = RuntimeSnapshot.Phase

/// One change the engine wants committed to the shared store's change index.
/// The node owner applies these through `NodeStore` (single writer for the node
/// group), so the engine never writes the store directly (contract 5).
public struct EngineChange: Hashable, Sendable {
    public let entity: Change.Entity
    public let key: String
    public let identityID: IdentityID?
    public let revision: Counter
    public let removed: Bool
    public init(entity: Change.Entity, key: String, identityID: IdentityID?,
                revision: Counter, removed: Bool) {
        self.entity = entity
        self.key = key
        self.identityID = identityID
        self.revision = revision
        self.removed = removed
    }
}

/// Result of executing an admitted command. The engine returns a typed outcome;
/// the node owner maps it to a `CommandRecord` disposition and any change-index
/// commit. A `.rejected` carries the typed error that becomes the committed
/// rejection (contract 3.4).
public enum EngineCommandResult: Hashable, Sendable {
    case ok(EngineChange?)
    case rejected(NodeError)
    case interrupted
}

/// The engine-adapter seam. An engine is constructed per NE boot (one node
/// owner, one engine). The node owner is a serialized actor and drives the
/// engine on its own executor, so the lifecycle + side-effect calls are `async`
/// (the real engines - the C++ microRNS node and embedded Python RNS - are
/// long-running + async). The capability gate (`canExecute`) stays synchronous:
/// it is a pure state check the store's admission policy calls inside its
/// transaction, and must not do I/O. The engine must not block on app IPC.
public protocol NodeEngine: Sendable {
    /// Build info for the descriptor (IDL `record BuildInfo`).
    var buildInfo: BuildInfo { get }

    /// Capabilities this engine advertises in hello (IDL `[Capability]`).
    var capabilities: [Capability] { get }

    /// Bring the node up. Called once at start (and on act `.start`). Returns the
    /// descriptor the node owner returns to hello (contract 6). Throws on a hard
    /// startup failure.
    func start(store: NodeStore) async throws -> Descriptor

    /// Stop the node. Idempotent. Called at tunnel teardown / quiesce.
    func stop() async

    /// Current runtime snapshot (phase/enabled/connectivity) for a nodeState
    /// query.
    func runtimeSnapshot() async -> RuntimeSnapshot

    /// Execute an admitted command. `intent` is the already-staged intent; the
    /// node owner has already committed an `accepted` ledger disposition, so this
    /// is the actual side effect (send, configure, etc.). The engine must not
    /// re-stage or re-admit.
    func execute(_ intent: Intent) async throws -> EngineCommandResult

    /// Whether the engine can run `command` NOW (capability/scope check) for the
    /// admission policy. A non-nil here means "cannot run; reject". This is the
    /// capability gate the store's admission policy calls (contract 7, 11).
    /// Synchronous: it runs inside the store's admission transaction.
    func canExecute(_ intent: Intent) -> NodeError?
}

extension NodeEngine {
    /// Default: an engine that only does durable messaging. Override to gate
    /// other command classes.
    public func canExecute(_ intent: Intent) -> NodeError? {
        if capability(feature: .durableMessaging) == .supported { return nil }
        return NodeError(code: .featureDisabled,
                         message: "engine does not support durableMessaging")
    }

    /// Convenience: look up a capability's support level.
    public func capability(feature: Feature) -> Capability.Support {
        capabilities.first(where: { $0.feature == feature })?.support ?? .unsupported
    }
}

/// A no-op engine used by unit tests and as the default before a real engine is
/// wired into the NE. It advertises nothing and refuses every command, which is
/// the correct fail-closed behavior when no engine is installed.
public struct StubEngine: NodeEngine {
    public init() {}
    public var buildInfo: BuildInfo {
        BuildInfo(name: "stub", revision: "0", adapterRevision: "0")
    }
    public var capabilities: [Capability] { [] }

    public func start(store: NodeStore) async throws -> Descriptor {
        Descriptor(version: .v1_0, storeEpoch: store.epochValue, bootID: BootID(),
                   storeSchema: 1, capabilities: [],
                   backend: buildInfo,
                   runtime: RuntimeSnapshot(bootID: BootID(), phase: .ready,
                                            desiredEnabled: false, actualEnabled: false,
                                            enabledIdentities: [], connectivity: .noInterfaces,
                                            observedAt: Instant(date: Date())))
    }
    public func stop() async {}
    public func runtimeSnapshot() async -> RuntimeSnapshot {
        RuntimeSnapshot(bootID: BootID(), phase: .ready, desiredEnabled: false,
                        actualEnabled: false, enabledIdentities: [],
                        connectivity: .noInterfaces, observedAt: Instant(date: Date()))
    }
    public func execute(_ intent: Intent) async throws -> EngineCommandResult {
        .rejected(NodeError(code: .unavailable, message: "stub engine has no backing node"))
    }
    public func canExecute(_ intent: Intent) -> NodeError? {
        NodeError(code: .featureDisabled, message: "stub engine has no backing node")
    }
}
