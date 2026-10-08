//
//  ControlTypes.swift
//  ColumbaNode
//
//  The control-channel wire types (IDL `record Request`/`Reply`, contract 6).
//  These are the JSON payloads that ride inside the `[0xF5, 0x02]` framing on
//  the bounded app<->NE control channel. The complete command body is NEVER sent
//  inline: the facade stages it durably in the shared store first, and `admit`
//  carries only the commandID (contract 3.3, 6).
//
//  JSON shapes mirror the IDL field-by-field (tagged unions as {tag, value});
//  the codec in ControlChannel.swift encodes/decodes these to canonical JSON.
//

import Foundation

/// Wire version. Contract version is independently `{major:1, minor:0}`.
public struct Version: Hashable, Sendable, JsonEncodable {
    public let major: UInt64
    public let minor: UInt64
    public init(major: UInt64, minor: UInt64) {
        self.major = major
        self.minor = minor
    }
    public static let v1_0 = Version(major: 1, minor: 0)
    public var jsonValue: JsonValue {
        .object(["major": .uint(major), "minor": .uint(minor)])
    }
}

/// Session context carried by every non-hello request (contract 6).
public struct Session: Hashable, Sendable, JsonEncodable {
    public let version: Version
    public let storeEpoch: StoreEpoch
    public let bootID: BootID
    public init(version: Version, storeEpoch: StoreEpoch, bootID: BootID) {
        self.version = version
        self.storeEpoch = storeEpoch
        self.bootID = bootID
    }
    public var jsonValue: JsonValue {
        .object([
            "version": version.jsonValue,
            "storeEpoch": .string(storeEpoch.wire),
            "bootID": .string(bootID.wire),
        ])
    }
}

/// One request on the control channel (IDL `record Request`).
public enum RequestBody: Hashable, Sendable {
    /// Hello: establish session + exchange descriptor. Exempt from session context.
    case hello(versions: [Version], schemaMin: UInt64, schemaMax: UInt64)
    /// Admit a staged command (the complete body is already in the shared store).
    case admit(session: Session, commandID: CommandID)
    /// Read-only query.
    case query(session: Session, query: Query)
    /// Session-only action (boot-scoped, never replayed).
    case act(session: Session, actionID: ActionID, action: Action)

    var tag: String {
        switch self {
        case .hello: return "hello"
        case .admit: return "admit"
        case .query: return "query"
        case .act: return "act"
        }
    }
    public var jsonValue: JsonValue {
        switch self {
        case let .hello(versions, min, max):
            return .object([
                "tag": .string("hello"),
                "value": .object([
                    "versions": .array(versions.map { $0.jsonValue }),
                    "schemaMin": .uint(min),
                    "schemaMax": .uint(max),
                ]),
            ])
        case let .admit(session, commandID):
            return .object([
                "tag": .string("admit"),
                "value": .object([
                    "session": session.jsonValue,
                    "commandID": .string(commandID.wire),
                ]),
            ])
        case let .query(session, query):
            return .object([
                "tag": .string("query"),
                "value": .object([
                    "session": session.jsonValue,
                    "query": query.jsonValue,
                ]),
            ])
        case let .act(session, actionID, action):
            return .object([
                "tag": .string("act"),
                "value": .object([
                    "session": session.jsonValue,
                    "actionID": .string(actionID.wire),
                    "action": action.jsonValue,
                ]),
            ])
        }
    }
}

/// One reply on the control channel (IDL `record Reply`).
public struct Reply: Hashable, Sendable, JsonEncodable {
    public let requestID: RequestID
    public let storeEpoch: StoreEpoch?
    public let bootID: BootID?
    public let result: Result

    public enum Result: Hashable, Sendable {
        case success(ReplyValue)
        case failure(NodeError)
    }

    public init(requestID: RequestID, storeEpoch: StoreEpoch?, bootID: BootID?, result: Result) {
        self.requestID = requestID
        self.storeEpoch = storeEpoch
        self.bootID = bootID
        self.result = result
    }

    public var jsonValue: JsonValue {
        let resultValue: JsonValue
        switch result {
        case .success(let value):
            resultValue = .object(["tag": .string("success"), "value": value.jsonValue])
        case .failure(let error):
            resultValue = .object(["tag": .string("failure"), "value": error.jsonValue])
        }
        var obj: [String: JsonValue] = [
            "requestID": .string(requestID.wire),
            "result": resultValue,
        ]
        if let e = storeEpoch { obj["storeEpoch"] = .string(e.wire) }
        if let b = bootID { obj["bootID"] = .string(b.wire) }
        return .object(obj)
    }
}

/// The value half of a successful reply (IDL `union ReplyValue`).
public enum ReplyValue: Hashable, Sendable {
    case hello(Descriptor)
    case admission(CommandRecord)
    case query(QueryResult)
    case action(ActionResult)

    var tag: String {
        switch self {
        case .hello: return "hello"
        case .admission: return "admission"
        case .query: return "query"
        case .action: return "action"
        }
    }
    public var jsonValue: JsonValue {
        switch self {
        case let .hello(d): return .object(["tag": .string("hello"), "value": d.jsonValue])
        case let .admission(r): return .object(["tag": .string("admission"), "value": r.jsonValue])
        case let .query(r): return .object(["tag": .string("query"), "value": r.jsonValue])
        case let .action(r): return .object(["tag": .string("action"), "value": r.jsonValue])
        }
    }
}

/// The node descriptor returned by hello (IDL `record Descriptor`).
public struct Descriptor: Hashable, Sendable, JsonEncodable {
    public let version: Version
    public let storeEpoch: StoreEpoch
    public let bootID: BootID
    public let storeSchema: UInt64
    public let capabilities: [Capability]
    public let backend: BuildInfo
    public let runtime: RuntimeSnapshot

    public init(version: Version, storeEpoch: StoreEpoch, bootID: BootID, storeSchema: UInt64,
                capabilities: [Capability], backend: BuildInfo, runtime: RuntimeSnapshot) {
        self.version = version
        self.storeEpoch = storeEpoch
        self.bootID = bootID
        self.storeSchema = storeSchema
        self.capabilities = capabilities
        self.backend = backend
        self.runtime = runtime
    }
    public var jsonValue: JsonValue {
        .object([
            "version": version.jsonValue,
            "storeEpoch": .string(storeEpoch.wire),
            "bootID": .string(bootID.wire),
            "storeSchema": .uint(storeSchema),
            "capabilities": .array(capabilities.map { $0.jsonValue }),
            "backend": backend.jsonValue,
            "runtime": runtime.jsonValue,
        ])
    }
}

public struct Capability: Hashable, Sendable, JsonEncodable {
    public let feature: Feature
    public let support: Support
    public let availability: Availability
    public let reason: String?

    public enum Support: String, Sendable { case unsupported, experimental, supported }
    public init(feature: Feature, support: Support, availability: Availability, reason: String?) {
        self.feature = feature
        self.support = support
        self.availability = availability
        self.reason = reason
    }
    public var jsonValue: JsonValue {
        var o: [String: JsonValue] = [
            "feature": .string(feature.rawValue),
            "support": .string(support.rawValue),
            "availability": .string(availability.rawValue),
        ]
        if let reason { o["reason"] = .string(reason) }
        return .object(o)
    }
}

public struct BuildInfo: Hashable, Sendable, JsonEncodable {
    public let name: String
    public let revision: String
    public let adapterRevision: String
    public init(name: String, revision: String, adapterRevision: String) {
        self.name = name
        self.revision = revision
        self.adapterRevision = adapterRevision
    }
    public var jsonValue: JsonValue {
        .object(["name": .string(name), "revision": .string(revision),
                 "adapterRevision": .string(adapterRevision)])
    }
}

public struct RuntimeSnapshot: Hashable, Sendable, JsonEncodable {
    public enum Phase: String, Sendable {
        case starting, recovering, ready, degraded, quiescing, stopped, failed
    }
    public enum Connectivity: String, Sendable {
        case noInterfaces, interfacesAvailable, unknown
    }
    public let bootID: BootID
    public let phase: Phase
    public let desiredEnabled: Bool
    public let actualEnabled: Bool
    public let enabledIdentities: [IdentityID]
    public let connectivity: Connectivity
    public let observedAt: Instant

    public init(bootID: BootID, phase: Phase, desiredEnabled: Bool, actualEnabled: Bool,
                enabledIdentities: [IdentityID], connectivity: Connectivity, observedAt: Instant) {
        self.bootID = bootID
        self.phase = phase
        self.desiredEnabled = desiredEnabled
        self.actualEnabled = actualEnabled
        self.enabledIdentities = enabledIdentities
        self.connectivity = connectivity
        self.observedAt = observedAt
    }
    public var jsonValue: JsonValue {
        .object([
            "bootID": .string(bootID.wire),
            "phase": .string(phase.rawValue),
            "desiredEnabled": .bool(desiredEnabled),
            "actualEnabled": .bool(actualEnabled),
            "enabledIdentities": .array(enabledIdentities.map { .string($0.wire) }),
            "connectivity": .string(connectivity.rawValue),
            "observedAt": .int(observedAt.epochMillis),
        ])
    }
}

/// A read-only query (IDL `union Query`). The first slice covers the text-
/// messaging vertical + identity/status reads.
public enum Query: Hashable, Sendable {
    case nodeState
    case identity(IdentityID)
    case identities
    case operation(OperationID)
    case conversations(page: Int?, token: String?)
    case conversationMessages(destination: DestinationHash, identity: IdentityID,
                               beforeLocalSequence: UInt64?, limit: Int, token: String?)
    case reachability(destination: DestinationHash)

    var tag: String {
        switch self {
        case .nodeState: return "nodeState"
        case .identity: return "identity"
        case .identities: return "identities"
        case .operation: return "operation"
        case .conversations: return "conversations"
        case .conversationMessages: return "conversationMessages"
        case .reachability: return "reachability"
        }
    }
    public var jsonValue: JsonValue {
        switch self {
        case .nodeState:
            return .object(["tag": .string("nodeState"), "value": .object([:])])
        case let .identity(id):
            return .object(["tag": .string("identity"),
                            "value": .object(["identityID": .string(id.wire)])])
        case .identities:
            return .object(["tag": .string("identities"), "value": .object([:])])
        case let .operation(id):
            return .object(["tag": .string("operation"),
                            "value": .object(["operationID": .string(id.wire)])])
        case let .conversations(page, token):
            var o: [String: JsonValue] = [:]
            if let page { o["page"] = .uint(UInt64(page)) }
            if let token { o["token"] = .string(token) }
            return .object(["tag": .string("conversations"), "value": .object(o)])
        case let .conversationMessages(destination, identity, before, limit, token):
            var o: [String: JsonValue] = [
                "destination": .string(destination.hex),
                "identityID": .string(identity.wire),
                "limit": .uint(UInt64(limit)),
            ]
            if let before { o["beforeLocalSequence"] = .uint(before) }
            if let token { o["token"] = .string(token) }
            return .object(["tag": .string("conversationMessages"), "value": .object(o)])
        case let .reachability(destination):
            return .object(["tag": .string("reachability"),
                            "value": .object(["destination": .string(destination.hex)])])
        }
    }
}

/// A session-only action (IDL `union Action`). First slice: transmit gate + call
/// attach are app-host concerns; the node-side actions here are lifecycle + the
/// outbound transmit gate the node enforces.
public enum Action: Hashable, Sendable {
    case start
    case stop
    case transmitGate(IdentityID, enabled: Bool)

    var tag: String {
        switch self {
        case .start: return "start"
        case .stop: return "stop"
        case .transmitGate: return "transmitGate"
        }
    }
    public var jsonValue: JsonValue {
        switch self {
        case .start: return .object(["tag": .string("start"), "value": .object([:])])
        case .stop: return .object(["tag": .string("stop"), "value": .object([:])])
        case let .transmitGate(id, enabled):
            return .object(["tag": .string("transmitGate"),
                            "value": .object(["identityID": .string(id.wire),
                                              "enabled": .bool(enabled)])])
        }
    }
}

/// A query result (IDL `union QueryResult`). First slice: nodeState, identity,
/// identities, operation. (Conversation/message pages added with the read model.)
public enum QueryResult: Hashable, Sendable {
    case nodeState(Descriptor)
    case identity(IdentityRecord)
    case identities([IdentityRecord])
    case operation(OperationRecord)

    var tag: String {
        switch self {
        case .nodeState: return "nodeState"
        case .identity: return "identity"
        case .identities: return "identities"
        case .operation: return "operation"
        }
    }
    public var jsonValue: JsonValue {
        switch self {
        case let .nodeState(d):
            return .object(["tag": .string("nodeState"), "value": d.jsonValue])
        case let .identity(r):
            return .object(["tag": .string("identity"), "value": r.jsonValue])
        case let .identities(list):
            return .object(["tag": .string("identities"),
                            "value": .object(["items": .array(list.map { $0.jsonValue })])])
        case let .operation(r):
            return .object(["tag": .string("operation"), "value": r.jsonValue])
        }
    }
}

/// An action result (IDL `union ActionResult`). First slice: unit + identity.
public enum ActionResult: Hashable, Sendable {
    case unit
    case identity(IdentityRecord)

    var tag: String {
        switch self {
        case .unit: return "unit"
        case .identity: return "identity"
        }
    }
    public var jsonValue: JsonValue {
        switch self {
        case .unit:
            return .object(["tag": .string("unit"), "value": .object([:])])
        case let .identity(r):
            return .object(["tag": .string("identity"), "value": r.jsonValue])
        }
    }
}

/// An identity record (IDL `record IdentityRecord`).
public struct IdentityRecord: Hashable, Sendable, JsonEncodable {
    public let id: IdentityID
    public let identityHash: IdentityHash
    public let deliveryDestination: DestinationHash
    public let profile: IdentityProfile
    public let revision: UInt64
    public let retired: Bool
    public let keyAvailable: Bool
    public let desiredEnabled: Bool
    public let actualEnabled: Bool

    public init(id: IdentityID, identityHash: IdentityHash, deliveryDestination: DestinationHash,
                profile: IdentityProfile, revision: UInt64, retired: Bool, keyAvailable: Bool,
                desiredEnabled: Bool, actualEnabled: Bool) {
        self.id = id
        self.identityHash = identityHash
        self.deliveryDestination = deliveryDestination
        self.profile = profile
        self.revision = revision
        self.retired = retired
        self.keyAvailable = keyAvailable
        self.desiredEnabled = desiredEnabled
        self.actualEnabled = actualEnabled
    }
    public var jsonValue: JsonValue {
        .object([
            "id": .string(id.wire),
            "identityHash": .string(identityHash.hex),
            "deliveryDestination": .string(deliveryDestination.hex),
            "profile": profile.jsonValue,
            "revision": .uint(revision),
            "retired": .bool(retired),
            "keyAvailable": .bool(keyAvailable),
            "desiredEnabled": .bool(desiredEnabled),
            "actualEnabled": .bool(actualEnabled),
        ])
    }
}

public struct IdentityProfile: Hashable, Sendable, JsonEncodable {
    public let name: String
    public let announceIntervalMs: UInt64?
    public init(name: String, announceIntervalMs: UInt64? = nil) {
        self.name = name
        self.announceIntervalMs = announceIntervalMs
    }
    public var jsonValue: JsonValue {
        var o: [String: JsonValue] = ["name": .string(name)]
        if let announceIntervalMs { o["announceIntervalMs"] = .uint(announceIntervalMs) }
        return .object(o)
    }
}

/// An operation record (IDL `record Operation`).
public struct OperationRecord: Hashable, Sendable, JsonEncodable {
    public enum State: String, Sendable {
        case queued, blocked, running, succeeded, failed, cancelled, interrupted
    }
    public let id: OperationID
    public let commandID: CommandID
    public let kind: String
    public let state: State
    public let createdAt: Instant
    public let finishedAt: Instant?

    public init(id: OperationID, commandID: CommandID, kind: String, state: State,
                createdAt: Instant, finishedAt: Instant?) {
        self.id = id
        self.commandID = commandID
        self.kind = kind
        self.state = state
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
    public var jsonValue: JsonValue {
        var o: [String: JsonValue] = [
            "id": .string(id.wire),
            "commandID": .string(commandID.wire),
            "kind": .string(kind),
            "state": .string(state.rawValue),
            "createdAt": .int(createdAt.epochMillis),
        ]
        if let finishedAt { o["finishedAt"] = .int(finishedAt.epochMillis) }
        return .object(o)
    }
}
