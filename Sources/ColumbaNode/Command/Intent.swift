//
//  Intent.swift
//  ColumbaNode
//
//  The staged, durable, immutable command intent (IDL `record Intent`, contract 3).
//
//  The facade ALWAYS stages an Intent durably before sending control IPC. The
//  node reads the complete intent from the shared store; the `admit` control
//  message references only the commandID.
//
//  The canonical body digest (contract 3) covers the ENTIRE normalized Intent —
//  storeEpoch, commandID, createdAt, expiresAt, afterCommandID and body — with
//  NO mutable staging metadata. That digest is the idempotency key:
//    - same (storeEpoch, commandID) + same canonical body → the original receipt
//    - same key + different canonical body → idempotencyConflict
//
//  This mirrors `examples.json`: `canonicalIntentUTF8` is the RFC 8785 form of
//  exactly these fields, and `bodySHA256` is SHA-256 over those bytes.
//

import Foundation

public struct Intent: Hashable, Sendable, JsonEncodable {
    public let storeEpoch: StoreEpoch
    public let commandID: CommandID
    /// When the app first staged this intent. Facade retries REUSE the first
    /// staged timestamp — never reconstructed under the same commandID.
    public let createdAt: Instant
    /// Limits NEW admission. An accepted job's deadline is separately in its body.
    public let expiresAt: Instant?
    /// Optional dependency: admission waits for this earlier intent's success.
    public let afterCommandID: CommandID?
    public let body: Command

    public init(storeEpoch: StoreEpoch, commandID: CommandID, createdAt: Instant,
                expiresAt: Instant? = nil, afterCommandID: CommandID? = nil, body: Command) {
        self.storeEpoch = storeEpoch
        self.commandID = commandID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.afterCommandID = afterCommandID
        self.body = body
    }

    /// RFC 8785 canonical bytes of the whole normalized Intent.
    ///
    /// Field order is irrelevant (object keys are canonically sorted), but the
    /// SET of fields is fixed: afterCommandID, body, commandID, createdAt,
    /// expiresAt, storeEpoch. Absent optionals encode as explicit null.
    public var jsonValue: JsonValue {
        .object([
            "storeEpoch": .string(storeEpoch.wire),
            "commandID": .string(commandID.wire),
            "createdAt": .number(createdAt.wire),
            "expiresAt": expiresAt.map { .number($0.wire) } ?? .null,
            "afterCommandID": afterCommandID.map { .string($0.wire) } ?? .null,
            "body": body.jsonValue,
        ])
    }
}

// MARK: - Receipts + ledger records

/// Returned to the app immediately when staging succeeds (state == .staged).
/// The outbound MessageID and async OperationID equal the initial CommandID, in
/// their distinct types (contract 3.1).
public struct LocalReceipt: Hashable, Sendable {
    public enum State: String, Sendable { case staged, abandoned, accepted, rejected }
    public let commandID: CommandID
    public let messageID: MessageID?
    public let operationID: OperationID
    public let localSequence: Counter?
    public let state: State
    public let stagedAt: Instant
    public init(commandID: CommandID, messageID: MessageID?, operationID: OperationID,
                localSequence: Counter?, state: State, stagedAt: Instant) {
        self.commandID = commandID
        self.messageID = messageID
        self.operationID = operationID
        self.localSequence = localSequence
        self.state = state
        self.stagedAt = stagedAt
    }
}

/// The node's committed disposition of a command (IDL `record CommandRecord`).
public struct CommandRecord: Hashable, Sendable {
    public enum Disposition: String, Sendable { case accepted, rejected, retired }
    public let commandID: CommandID
    public let bodyDigest: Digest
    public let disposition: Disposition
    public let acceptedAt: Instant?
    public let operationID: OperationID?
    public let rejection: NodeError?
    public let committedThrough: Cursor?
    public init(commandID: CommandID, bodyDigest: Digest, disposition: Disposition,
                acceptedAt: Instant?, operationID: OperationID?, rejection: NodeError?, committedThrough: Cursor?) {
        self.commandID = commandID
        self.bodyDigest = bodyDigest
        self.disposition = disposition
        self.acceptedAt = acceptedAt
        self.operationID = operationID
        self.rejection = rejection
        self.committedThrough = committedThrough
    }
}

extension CommandRecord: JsonEncodable {
    public var jsonValue: JsonValue {
        var o: [String: JsonValue] = [
            "commandID": .string(commandID.wire),
            "bodyDigest": .string(bodyDigest.hex),
            "disposition": .string(disposition.rawValue),
        ]
        if let acceptedAt { o["acceptedAt"] = .int(acceptedAt.epochMillis) }
        if let operationID { o["operationID"] = .string(operationID.wire) }
        if let rejection { o["rejection"] = rejection.jsonValue }
        if let committedThrough {
            o["committedThrough"] = .object([
                "storeEpoch": .string(committedThrough.storeEpoch.wire),
                "sequence": .uint(committedThrough.sequence.value),
            ])
        }
        return .object(o)
    }
}
