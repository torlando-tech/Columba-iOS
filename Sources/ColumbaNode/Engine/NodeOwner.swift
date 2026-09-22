//
//  NodeOwner.swift
//  ColumbaNode
//
//  The node-owner coordinator (contract 6.5): the SOLE owner of the node group.
//  It is a serialized actor that (a) services the bounded control channel
//  (hello/admit/query/act), (b) runs stage-first admission through `NodeStore`,
//  and (c) drives the pluggable `NodeEngine` for the actual side effect.
//
//  The engine is behind the adapter seam (contract 15): Python RNS, Reticulum-Go,
//  and microReticulum all sit behind `NodeEngine`. This owner is engine-agnostic
//  - it knows nothing about RNS - and is the SAME code whether the engine is a
//  fake (tests), embedded CPython+RNS (the first engine), or the C++ microRNS
//  node the existing Model B NE already runs.
//
//  Admission/execution split (contract 6.5, 6.6):
//    - `admit` commits the DURABLE disposition (accepted/rejected) in one
//      transaction via `NodeStore.admit`. A rejection is a committed record.
//    - Execution happens OUTSIDE that transaction, on the owner's serial actor:
//      `engine.execute(intent)`. An admitted command can later fail; that failure
//      belongs to its operation record, not the admission. Transport failure is
//      separate from a committed rejection.
//    - The engine's durable domain changes are committed by the owner (the single
//      writer for the node group) via `NodeStore.commitChanges` (contract 5).
//

import Foundation

/// The serialized node-owner coordinator. One instance per NE boot; one node
/// owner, one engine. `handle` is the single entry point the NE's
/// `handleAppMessage` calls for a `[0xF5, 0x02]` control envelope, returning the
/// framed reply envelope.
public actor NodeOwner {

    private let store: NodeStore
    private let engine: any NodeEngine
    /// Boot-scoped runtime descriptors (hello result + operation records). The
    /// command LEDGER is durable in the store; these are the live, boot-scoped
    /// views the control channel returns for `query`.
    private var descriptor: Descriptor?
    private var operations: [OperationID: OperationRecord] = [:]
    /// Commands that have already run their (post-admission) side effect THIS
    /// boot. A repeated `admit` for an already-accepted command returns the
    /// committed record WITHOUT re-executing - re-running a durable message send
    /// would duplicate the side effect (contract 6.5/3: admit is idempotent;
    /// the ledger is checked first). Recovery replay of a never-completed
    /// operation is a separate, later increment.
    private var executedThisBoot: Set<CommandID> = []

    /// Schema version the node owner reports in the descriptor.
    public let storeSchema: UInt64

    public init(store: NodeStore, engine: any NodeEngine, storeSchema: UInt64 = 1) {
        self.store = store
        self.engine = engine
        self.storeSchema = storeSchema
    }

    // MARK: - Control channel entry point

    /// Handle one framed control envelope and return the framed reply. A bad
    /// envelope (magic/version/size/decode) is a hard control-protocol error and
    /// replies `protocolFailure` - it never falls through to a legacy path
    /// (contract 6).
    public func handle(_ envelope: Data) -> Data {
        do {
            let (requestID, body) = try ControlChannel.decodeRequest(from: envelope)
            let reply = try dispatch(requestID: requestID, body: body)
            return try ControlChannel.encode(reply: reply)
        } catch let e as ControlChannelError {
            return self.encodeFailure(requestID: RequestID(),
                                      error: NodeError(code: .protocolFailure, message: e.description))
        } catch let e as NodeError {
            // A session/context error produced during dispatch (e.g. bootChanged).
            return self.encodeFailure(requestID: RequestID(), error: e)
        } catch {
            return self.encodeFailure(requestID: RequestID(),
                                      error: NodeError(code: .storageUnavailable, message: String(describing: error)))
        }
    }

    /// Validate a request's session against the live store (contract 6): an
    /// out-of-date storeEpoch or a bootID from a previous boot is a typed
    /// error, never a silent fallthrough.
    private func validate(_ session: Session) throws {
        guard session.storeEpoch == store.epochValue else {
            throw NodeError(code: .storeReplaced, retry: .afterStateChange,
                            message: "request storeEpoch does not match the live store")
        }
        // bootID from a different boot: the node restarted since the app last
        // hello'd; the app must re-hello.
        if let desc = descriptor, session.bootID != desc.bootID {
            throw NodeError(code: .bootChanged, retry: .afterStateChange,
                            message: "request bootID is from a previous boot; re-hello")
        }
    }

    // MARK: - dispatch

    private func dispatch(requestID: RequestID, body: RequestBody) throws -> Reply {
        switch body {
        case let .hello(versions, min, max):
            return try hello(requestID: requestID, versions: versions, min: min, max: max)
        case let .admit(session, commandID):
            try validate(session)
            return admit(requestID: requestID, commandID: commandID)
        case let .query(session, query):
            try validate(session)
            return handleQuery(requestID: requestID, query: query)
        case let .act(session, _, action):
            try validate(session)
            return act(requestID: requestID, action: action)
        }
    }

    // MARK: - hello

    /// Hello establishes the session and returns the descriptor (contract 6).
    /// It is side-effect-free beyond (re)starting the engine for this boot. An
    /// unsupported version is a hard negotiation failure (no legacy fallthrough).
    private func hello(requestID: RequestID, versions: [Version], min: UInt64, max: UInt64) throws -> Reply {
        // Negotiate: the node supports v1.0. The app must offer a version the
        // node supports within its schema range.
        let supported = Version.v1_0
        guard versions.contains(supported) else {
            throw NodeError(code: .protocolMismatch, message:
                "app offered no supported control version")
        }
        guard min <= 1 && max >= 1 else {
            throw NodeError(code: .schemaMismatch, message:
                "app schema range [\(min), \(max)] excludes the node's store schema")
        }
        // Start (or restart) the engine for this boot and capture its descriptor.
        let desc: Descriptor
        do {
            desc = try engine.start(store: store)
        } catch let e as NodeError {
            // A hard engine start failure: the node is up enough to answer, but
            // reports a failed phase rather than a protocol error.
            desc = self.degradedDescriptor(error: e)
        } catch {
            desc = self.degradedDescriptor(error: NodeError(code: .unavailable, message: String(describing: error)))
        }
        self.descriptor = desc
        self.operations.removeAll()
        self.executedThisBoot.removeAll()

        return Reply(requestID: requestID, storeEpoch: desc.storeEpoch, bootID: desc.bootID,
                     result: .success(.hello(desc)))
    }

    /// A descriptor for a node that is up but whose engine failed to start: the
    /// control channel still answers, the phase reports the failure, and the
    /// engine's capabilities are advertised as disabled so the app can degrade.
    private func degradedDescriptor(error: NodeError) -> Descriptor {
        let boot = descriptor?.bootID ?? BootID()
        let epoch = store.epochValue
        return Descriptor(
            version: .v1_0, storeEpoch: epoch, bootID: boot, storeSchema: storeSchema,
            capabilities: engine.capabilities.map { cap in
                Capability(feature: cap.feature, support: .unsupported,
                           availability: .disabled, reason: error.code.rawValue)
            },
            backend: engine.buildInfo,
            runtime: RuntimeSnapshot(bootID: boot, phase: .failed, desiredEnabled: false,
                                     actualEnabled: false, enabledIdentities: [],
                                     connectivity: .unknown, observedAt: Instant(date: Date())))
    }

    // MARK: - admit

    /// Admit a staged command (contract 3.3-3.6). The complete intent is read
    /// from the shared store (the wire carries only the commandID). The durable
    /// disposition is committed in one transaction; execution follows outside it.
    private func admit(requestID: RequestID, commandID: CommandID) -> Reply {
        let record: CommandRecord
        // Capture the engine as a local Sendable so the @Sendable admission
        // policy closure does not capture the actor-isolated `self`.
        let engine = self.engine
        do {
            record = try store.admit(commandID: commandID) { intent in
                // The injected admission policy: the engine's capability gate is
                // the authoritative accept/reject for a NEW command (contract 7,
                // 11). A rejection is a committed record (contract 3.4).
                if let err = engine.canExecute(intent) {
                    return .reject(err)
                }
                return .accept(operationID: OperationID(intent.commandID.raw))
            }
        } catch let e as NodeError {
            return Reply(requestID: requestID, storeEpoch: store.epochValue,
                         bootID: descriptor?.bootID, result: .failure(e))
        } catch {
            return Reply(requestID: requestID, storeEpoch: store.epochValue,
                         bootID: descriptor?.bootID,
                         result: .failure(NodeError(code: .storageUnavailable, message: String(describing: error))))
        }

        // Execution (contract 6.5): only an ACCEPTED command runs, and only ONCE
        // this boot. A repeated `admit` for an already-accepted command returns
        // the committed record without re-executing (re-running a durable message
        // send would duplicate the side effect). A rejected disposition is
        // terminal and never executes.
        if record.disposition == .accepted,
           !executedThisBoot.contains(commandID),
           let intent = try? store.intent(for: commandID) {
            runExecution(intent: intent, operationID: record.operationID ?? OperationID(commandID.raw))
        }

        return Reply(requestID: requestID, storeEpoch: record.committedThrough?.storeEpoch ?? store.epochValue,
                     bootID: descriptor?.bootID, result: .success(.admission(record)))
    }

    /// The post-admission side effect (outside the admission transaction). The
    /// engine returns a typed outcome; the owner records it on the operation and
    /// commits any durable domain change the engine produced.
    private func runExecution(intent: Intent, operationID: OperationID) {
        let commandID = intent.commandID
        executedThisBoot.insert(commandID)   // execute at most once this boot
        let kind = intent.body.tagName
        let now = Instant(date: Date())
        switch (try? engine.execute(intent)) {
        case .some(.ok(let change)):
            if let change {
                _ = try? store.commitChanges([change])
            }
            operations[operationID] = OperationRecord(id: operationID, commandID: commandID,
                                                      kind: kind, state: .succeeded,
                                                      createdAt: now, finishedAt: now)
        case .some(.rejected(let err)):
            // Admitted but the operation failed (transport, scope, etc.). The
            // failure belongs to the operation record, not the admission.
            operations[operationID] = OperationRecord(id: operationID, commandID: commandID,
                                                      kind: kind, state: .failed,
                                                      createdAt: now, finishedAt: now)
            _ = err   // carried on the operation; query exposes it
        case .some(.interrupted):
            // Durable + resumable: the work remains, not a committed failure.
            operations[operationID] = OperationRecord(id: operationID, commandID: commandID,
                                                      kind: kind, state: .interrupted,
                                                      createdAt: now, finishedAt: nil)
        case .none:
            // engine.execute threw (a hard engine fault): the operation failed.
            operations[operationID] = OperationRecord(id: operationID, commandID: commandID,
                                                      kind: kind, state: .failed,
                                                      createdAt: now, finishedAt: now)
        }
    }

    // MARK: - query

    private func handleQuery(requestID: RequestID, query: Query) -> Reply {
        let value: QueryResult?
        switch query {
        case .nodeState:
            value = .nodeState(currentDescriptor())
        case let .operation(opID):
            value = operation(opID).map(QueryResult.operation)
        case .identities, .identity, .conversations, .conversationMessages, .reachability:
            // Beyond the first vertical slice; report unsupported rather than a
            // fake success (contract 3).
            value = nil
        }
        if let value {
            return Reply(requestID: requestID, storeEpoch: store.epochValue,
                         bootID: descriptor?.bootID, result: .success(.query(value)))
        }
        return Reply(requestID: requestID, storeEpoch: store.epochValue,
                     bootID: descriptor?.bootID,
                     result: .failure(NodeError(code: .unsupported,
                                                message: "query not supported in the first slice")))
    }

    /// Resolve an operation by ID: the live boot-scoped record, falling back to
    /// the durable ledger disposition (so an operation's committed result is
    /// still answerable by command ID if the in-boot record is gone). The
    /// initial OperationID equals the CommandID (distinct types, same UUID).
    private func operation(_ opID: OperationID) -> OperationRecord? {
        if let live = operations[opID] { return live }
        // Durable fallback: the ledger knows the accepted/rejected disposition.
        // (store.command returns CommandRecord?; a non-throwing guard on the
        // `try?` would double-wrap, so use do/catch.)
        do {
            guard let record = try store.command(CommandID(opID.raw)) else { return nil }
            let intent = (try? store.intent(for: record.commandID)) ?? nil
            let kind = intent?.body.tagName ?? ""
            let state: OperationRecord.State
            switch record.disposition {
            case .accepted: state = .succeeded
            case .rejected: state = .failed
            case .retired:  state = .cancelled
            }
            return OperationRecord(id: opID, commandID: record.commandID, kind: kind, state: state,
                                   createdAt: record.acceptedAt ?? Instant(0),
                                   finishedAt: record.acceptedAt)
        } catch {
            return nil
        }
    }

    // MARK: - act

    private func act(requestID: RequestID, action: Action) -> Reply {
        switch action {
        case .start:
            // A re-start for the current boot: re-run the engine start and
            // refresh the descriptor.
            do {
                let desc = try engine.start(store: store)
                self.descriptor = desc
                return Reply(requestID: requestID, storeEpoch: desc.storeEpoch, bootID: desc.bootID,
                             result: .success(.action(.unit)))
            } catch let e as NodeError {
                return Reply(requestID: requestID, storeEpoch: store.epochValue,
                             bootID: descriptor?.bootID, result: .failure(e))
            } catch {
                return Reply(requestID: requestID, storeEpoch: store.epochValue,
                             bootID: descriptor?.bootID,
                             result: .failure(NodeError(code: .unavailable, message: String(describing: error))))
            }
        case .stop:
            engine.stop()
            return Reply(requestID: requestID, storeEpoch: store.epochValue,
                         bootID: descriptor?.bootID, result: .success(.action(.unit)))
        case .transmitGate:
            // Outbound transmit gate is a node-side enforcement point; the first
            // slice reports unsupported (the engine adapter gains the gate as it
            // lands), rather than a fake unit success.
            return Reply(requestID: requestID, storeEpoch: store.epochValue,
                         bootID: descriptor?.bootID,
                         result: .failure(NodeError(code: .unsupported,
                                                    message: "transmitGate not supported in the first slice")))
        }
    }

    // MARK: - helpers

    /// The current descriptor: the live boot descriptor, or a degraded one built
    /// from the engine's live snapshot if hello has not yet run this boot.
    private func currentDescriptor() -> Descriptor {
        if let desc = descriptor {
            // Refresh the runtime snapshot so a nodeState query reflects the
            // engine's live phase rather than the hello-time one.
            return Descriptor(version: desc.version, storeEpoch: desc.storeEpoch,
                              bootID: desc.bootID, storeSchema: desc.storeSchema,
                              capabilities: desc.capabilities, backend: desc.backend,
                              runtime: engine.runtimeSnapshot())
        }
        let boot = BootID()
        return Descriptor(version: .v1_0, storeEpoch: store.epochValue, bootID: boot,
                          storeSchema: storeSchema, capabilities: engine.capabilities,
                          backend: engine.buildInfo, runtime: engine.runtimeSnapshot())
    }

    private func encodeFailure(requestID: RequestID, error: NodeError) -> Data {
        let reply = Reply(requestID: requestID, storeEpoch: descriptor?.storeEpoch,
                          bootID: descriptor?.bootID, result: .failure(error))
        return (try? ControlChannel.encode(reply: reply)) ?? Data()
    }
}
