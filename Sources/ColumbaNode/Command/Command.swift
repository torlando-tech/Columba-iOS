//
//  Command.swift
//  ColumbaNode
//
//  The durable command vocabulary (IDL `union Command`, contract 3). A command is
//  an immutable, fully-specified unit of work that the facade stages durably
//  BEFORE any control IPC. The stable key is (storeEpoch, commandID); the body
//  digest (canonical RFC 8785 JSON of the normalized command body, SHA-256) is
//  what idempotency compares.
//
//  Canonicalization rules (contract 3):
//    - the digest covers the ENTIRE normalized command body (scope, deadline,
//      dependency), with no mutable staging metadata.
//    - absent optionals → null; declared defaults materialized; sets sorted by
//      canonical form; hashes/UUIDs lowercase; counters decimal.
//    - array order is significant (it is not a set).
//
//  Only the commands exercised by the current vertical slice have a canonical
//  body here; the rest throw on digest (honest — they are not implemented yet).
//

import Foundation

// MARK: - Scope + delivery policy

/// The identity a command acts for.
public struct Scope: Hashable, Sendable, JsonEncodable {
    public let identityID: IdentityID
    public init(identityID: IdentityID) { self.identityID = identityID }
    public var jsonValue: JsonValue { .object(["identityID": .string(identityID.wire)]) }
}

/// How a message should be delivered (contract 8). Distinct from observed method.
public struct DeliveryPolicy: Hashable, Sendable, JsonEncodable {
    public enum Preferred: String, Sendable {
        case automatic, direct, opportunistic, propagated
    }
    public let preferred: Preferred
    public let allowPropagationFallback: Bool
    public let maxAttempts: NonNegative
    public let stampBudgetMs: NonNegative
    public init(preferred: Preferred, allowPropagationFallback: Bool, maxAttempts: NonNegative, stampBudgetMs: NonNegative) {
        self.preferred = preferred
        self.allowPropagationFallback = allowPropagationFallback
        self.maxAttempts = maxAttempts
        self.stampBudgetMs = stampBudgetMs
    }
    public var jsonValue: JsonValue {
        .object([
            "preferred": .string(preferred.rawValue),
            "allowPropagationFallback": .boolean(allowPropagationFallback),
            "maxAttempts": .number(maxAttempts.wire),
            "stampBudgetMs": .number(stampBudgetMs.wire),
        ])
    }
}

// MARK: - Message payload (chat is the first vertical slice)

/// The typed message payload (IDL `union MessagePayload`). `chat` is the mandatory
/// first-slice variant; the others are declared for surface completeness.
public enum MessagePayload: Hashable, Sendable {
    case chat(ChatPayload)
    case reaction(ReactionPayload)
    case opaque(OpaquePayload)
    // telemetry / telemetryRequest are modeled in the telemetry increment.
}

public struct ChatPayload: Hashable, Sendable {
    /// Inline text (<= 16 KiB); longer content goes in a text blob.
    public let title: String?
    public let content: String
    public init(title: String? = nil, content: String) {
        self.title = title
        self.content = content
    }
}

public struct ReactionPayload: Hashable, Sendable {
    public let target: MessageHash
    public let emoji: String
    public let remove: Bool
    public init(target: MessageHash, emoji: String, remove: Bool = false) {
        self.target = target
        self.emoji = emoji
        self.remove = remove
    }
}

public struct OpaquePayload: Hashable, Sendable {
    public let title: String?
    public let content: String
    public let reason: String
    public init(title: String?, content: String, reason: String) {
        self.title = title
        self.content = content
        self.reason = reason
    }
}

extension MessagePayload: JsonEncodable {
    public var jsonValue: JsonValue {
        switch self {
        case .chat(let c):
            return .object([
                "tag": .string("chat"),
                "value": .object([
                    "title": .object(["tag": .string("inline"), "value": .string(c.title ?? "")]),
                    "content": .object(["tag": .string("inline"), "value": .string(c.content)]),
                    "attachments": .array([]),
                    "reply": .null,
                    "appearance": .null,
                    "extensions": .null,
                ]),
            ])
        case .reaction(let r):
            return .object([
                "tag": .string("reaction"),
                "value": .object([
                    "target": .string(r.target.hex),
                    "emoji": .string(r.emoji),
                    "remove": .boolean(r.remove),
                ]),
            ])
        case .opaque(let o):
            return .object([
                "tag": .string("opaque"),
                "value": .object([
                    "title": .object(["tag": .string("inline"), "value": .string(o.title ?? "")]),
                    "content": .object(["tag": .string("inline"), "value": .string(o.content)]),
                    "fields": .null,
                    "reason": .string(o.reason),
                ]),
            ])
        }
    }
}

// MARK: - The command union (subset: the durable vertical slice)

public enum Command: Hashable, Sendable {
    case submitMessage(submit: SubmitMessage)
    case retryMessage(retry: RetryMessage)
    case cancelOperation(target: OperationID)
    case createIdentity(name: String, requestedID: IdentityID)
    case setEnabledIdentities(expectedRevision: Counter, identities: Set<IdentityID>,
                              policy: SetEnabledPolicy, restart: RestartPolicy)
    case announce(scope: Scope, services: Set<AnnounceService>, deadline: Instant)
    case setBlackhole(identityHash: IdentityHash, enabled: Bool, expiresAt: Instant?)
    case purgeHistory(scope: Scope, conversation: DestinationHash?, through: Counter)

    public enum SetEnabledPolicy: String, Sendable { case requireIdle, suspendWork }
    public enum RestartPolicy: String, Sendable { case allowRestart, deferRestart }
    public enum AnnounceService: String, Sendable, Comparable { case delivery, telephony
        public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue } }
}

public struct SubmitMessage: Hashable, Sendable {
    public let scope: Scope
    public let destination: DestinationHash
    public let payload: MessagePayload
    public let delivery: DeliveryPolicy
    public let deadline: Instant?
    public init(scope: Scope, destination: DestinationHash, payload: MessagePayload, delivery: DeliveryPolicy, deadline: Instant?) {
        self.scope = scope
        self.destination = destination
        self.payload = payload
        self.delivery = delivery
        self.deadline = deadline
    }
}

public struct RetryMessage: Hashable, Sendable {
    public let scope: Scope
    public let messageID: MessageID
    public let deadline: Instant?
    public init(scope: Scope, messageID: MessageID, deadline: Instant?) {
        self.scope = scope
        self.messageID = messageID
        self.deadline = deadline
    }
}

extension Command: JsonEncodable {
    public var jsonValue: JsonValue {
        .object(["tag": .string(tagName), "value": valueJson])
    }

    public var tagName: String {
        switch self {
        case .submitMessage: return "submitMessage"
        case .retryMessage: return "retryMessage"
        case .cancelOperation: return "cancelOperation"
        case .createIdentity: return "createIdentity"
        case .setEnabledIdentities: return "setEnabledIdentities"
        case .announce: return "announce"
        case .setBlackhole: return "setBlackhole"
        case .purgeHistory: return "purgeHistory"
        }
    }

    var valueJson: JsonValue {
        switch self {
        case .submitMessage(let s):
            return .object([
                "scope": s.scope.jsonValue,
                "destination": .string(s.destination.hex),
                "payload": s.payload.jsonValue,
                "delivery": s.delivery.jsonValue,
                "deadline": s.deadline.map { .number($0.wire) } ?? .null,
            ])
        case .retryMessage(let r):
            return .object([
                "scope": r.scope.jsonValue,
                "messageID": .string(r.messageID.wire),
                "deadline": r.deadline.map { .number($0.wire) } ?? .null,
            ])
        case .cancelOperation(let target):
            return .object(["target": .string(target.wire)])
        case .createIdentity(let name, let requestedID):
            return .object([
                "name": .string(name),
                "requestedID": .string(requestedID.wire),
            ])
        case .setEnabledIdentities(let rev, let ids, let policy, let restart):
            // set<IdentityID> → canonically sorted array of wire strings.
            let sorted = ids.map { $0.wire }.sorted()
            return .object([
                "expectedRevision": .number(rev.wire),
                "identities": .array(sorted.map { .string($0) }),
                "policy": .string(policy.rawValue),
                "restart": .string(restart.rawValue),
            ])
        case .announce(let scope, let services, let deadline):
            let sorted = services.map { $0.rawValue }.sorted()
            return .object([
                "scope": scope.jsonValue,
                "services": .array(sorted.map { .string($0) }),
                "deadline": .number(deadline.wire),
            ])
        case .setBlackhole(let h, let enabled, let expiresAt):
            return .object([
                "identityHash": .string(h.hex),
                "enabled": .boolean(enabled),
                "expiresAt": expiresAt.map { .number($0.wire) } ?? .null,
            ])
        case .purgeHistory(let scope, let conversation, let through):
            return .object([
                "scope": scope.jsonValue,
                "conversation": conversation.map { .string($0.hex) } ?? .null,
                "through": .number(through.wire),
            ])
        }
    }
}

extension Instant {
    public var wire: String { String(epochMillis) }
}
