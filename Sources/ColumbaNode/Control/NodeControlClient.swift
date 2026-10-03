//
//  NodeControlClient.swift
//  ColumbaNode
//
//  The APP-SIDE client for the node-service v1 control channel (contract 6).
//
//  This is the app half of the seam: the app stages a command durably in the
//  SHARED store (the same WAL database the NE node owner opens), then drives
//  the NE over the bounded app->NE transport. The NE node owner (NodeOwner)
//  services `hello` + `admit`; the `admit` reply carries the committed
//  CommandRecord. The complete command body never crosses the wire - only the
//  commandID (contract 3.3, 6); the node reads the staged intent from the store.
//
//  Transport-injected (like `ProxyRnsBackend`): the app supplies the
//  `sendProviderMessage` closure; the client is testable with a stub transport
//  against a real store + a stub NE.
//
//  The legacy `ProxyRnsBackend` 0xF5 0x01 path is PRESERVED (contract 16); this
//  client is the NEW 0xF5 0x02 path that runs alongside it, not a replacement.

import Foundation

/// Errors raised by the app-side control client.
public enum NodeControlError: Error, LocalizedError, Equatable {
    /// The control envelope could not be built or decoded (the NE did not answer
    /// with a decodable `[0xF5 0x02]` reply).
    case transportFailed(operation: String)
    /// The NE node owner reported a typed control error (protocol, session, or
    /// admission failure). Carries the node's `NodeError`.
    case nodeRejected(operation: String, node: NodeError)
    /// Staging the intent in the shared store failed (e.g. idempotencyConflict).
    case stageFailed(String)
    /// No shared App-Group store is reachable (the client cannot stage).
    case storeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .transportFailed(let op): return "control transport failed: \(op)"
        case .nodeRejected(let op, let node): return "node rejected \(op): \(node.message)"
        case .stageFailed(let m): return "stage failed: \(m)"
        case .storeUnavailable(let m): return "store unavailable: \(m)"
        }
    }
}

/// The committed outcome of an app-driven `admit`.
public struct NodeAdmission: Equatable {
    public let commandID: CommandID
    public let record: CommandRecord
    public init(commandID: CommandID, record: CommandRecord) {
        self.commandID = commandID
        self.record = record
    }
}

/// App-side client for the node-service v1 control channel (contract 6).
///
/// Usage (the app's "send a message" path under the node contract):
///   1. `client.submitMessage(...)` stages a `submitMessage` intent in the shared
///      store, then `hello` + `admit` over the NE transport, returning the
///      committed `CommandRecord`.
///
/// `@unchecked Sendable`: stateless apart from the injected `send` closure
/// (itself `@Sendable`) - no mutable state to guard.
@available(iOS 17.0, macOS 14.0, *)
public final class NodeControlClient: @unchecked Sendable {
    /// Injected app->NE transport: send one framed envelope, return the NE's
    /// framed reply (or `nil` on a transport-level failure). The app supplies
    /// the `TunnelManager.proxySend` closure.
    private let send: @Sendable (Data) async -> Data?
    /// The shared App-Group store path (where the app stages intents). The NE
    /// opens the SAME path (AppGroupPaths.nodeServiceStoreURL).
    private let storeURL: String
    /// A stable per-app-boot identity ID for the command scope. The first slice
    /// does not validate the scope identity against the active identity (the node
    /// owner's `canExecute` is the capability gate), so a fixed ID is fine.
    private let scopeIdentity: IdentityID

    public init(send: @escaping @Sendable (Data) async -> Data?,
                storeURL: String,
                scopeIdentity: IdentityID = IdentityID()) {
        self.send = send
        self.storeURL = storeURL
        self.scopeIdentity = scopeIdentity
    }

    /// The one-shot control round-trip: encode a request, send it, decode the
    /// reply. Throws `NodeControlError.transportFailed` on a missing/undecodable
    /// reply; `NodeControlError.nodeRejected` on a typed failure result.
    private func roundTrip(_ body: RequestBody, op: String) async throws -> Reply {
        guard let envelope = try? ControlChannel.encode(request: body) else {
            throw NodeControlError.transportFailed(operation: op)
        }
        guard let replyData = await send(envelope),
              let reply = try? ControlChannel.decodeReply(from: replyData) else {
            throw NodeControlError.transportFailed(operation: op)
        }
        return reply
    }

    /// Hello establishes the session (contract 6) and returns the node
    /// descriptor. The app needs the descriptor's `storeEpoch` + `bootID` to
    /// build the session for a subsequent `admit`.
    @discardableResult
    public func hello() async throws -> Descriptor {
        let reply = try await roundTrip(.hello(versions: [.v1_0], schemaMin: 1, schemaMax: 1), op: "hello")
        guard case .success(.hello(let desc)) = reply.result else {
            throw NodeControlError.nodeRejected(operation: "hello", node: NodeError(code: .protocolFailure, message: "hello returned a non-success result"))
        }
        return desc
    }

    /// Submit a chat message via the node contract (contract 3, 6): stage a
    /// `submitMessage` intent durably in the shared store, then drive the NE
    /// with `hello` + `admit`, returning the node's committed `CommandRecord`.
    ///
    /// The app opens its OWN `NodeStore` handle on the shared file to stage -
    /// this is the contract's "stage-first" design: the durable intent is
    /// written BEFORE any control IPC, so a crash/retry is idempotent.
    @discardableResult
    public func submitMessage(
        destinationHex: String,
        content: String,
        method: DeliveryPolicy.Preferred = .automatic
    ) async throws -> NodeAdmission {
        guard let destination = DestinationHash(hex: destinationHex) else {
            throw NodeControlError.nodeRejected(operation: "submitMessage", node: NodeError.invalidArgument("destination", "bad destination hash"))
        }

        // 1. Stage the intent durably in the shared store (the wire carries only
        //    the commandID). A fresh store mints its own epoch; an existing
        //    store reuses it (the NE reads the same epoch).
        let store: NodeStore
        do {
            store = try NodeStore(config: .file(storeURL))
        } catch {
            throw NodeControlError.storeUnavailable(String(describing: error))
        }

        let commandID = CommandID()
        let intent = Intent(
            storeEpoch: store.epochValue,
            commandID: commandID,
            createdAt: Instant(date: Date()),
            body: .submitMessage(submit: SubmitMessage(
                scope: Scope(identityID: scopeIdentity),
                destination: destination,
                payload: .chat(ChatPayload(content: content)),
                delivery: DeliveryPolicy(preferred: method, allowPropagationFallback: false,
                                         maxAttempts: NonNegative(3), stampBudgetMs: NonNegative(0)),
                deadline: nil
            ))
        )

        let receipt: LocalReceipt
        do {
            switch try store.stage(intent) {
            case .staged(let r): receipt = r
            case .conflict(let e): throw NodeControlError.stageFailed(e.message ?? "stage conflict")
            }
        } catch let e as NodeControlError {
            throw e
        } catch {
            throw NodeControlError.stageFailed(String(describing: error))
        }

        // 2. Hello to establish the session (returns the live storeEpoch + bootID
        //    the node owner will validate against for the admit).
        let desc = try await hello()

        // 3. Admit the staged command. The node owner reads the intent from the
        //    shared store, commits the durable disposition in one transaction,
        //    then (if accepted) runs the engine side effect outside it.
        let session = Session(version: .v1_0, storeEpoch: desc.storeEpoch, bootID: desc.bootID)
        let reply = try await roundTrip(.admit(session: session, commandID: commandID), op: "admit")
        guard case .success(.admission(let record)) = reply.result else {
            throw NodeControlError.nodeRejected(operation: "admit", node: NodeError(code: .protocolFailure, message: "admit returned a non-success result"))
        }
        return NodeAdmission(commandID: commandID, record: record)
    }
}
