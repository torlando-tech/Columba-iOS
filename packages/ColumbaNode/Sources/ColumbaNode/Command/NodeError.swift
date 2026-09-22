//
//  NodeError.swift
//  ColumbaNode
//
//  The typed error model (IDL `record Error`, `enum ErrorCode`, contract 3).
//  A rejection carries code + optional field path + retry classification +
//  structured details. Never encode unsupported as an empty list or a fake
//  success (contract 3). Transport failure is separate from a committed
//  rejection (that distinction lives in the control channel, not here).
//

import Foundation

public struct NodeError: Hashable, Sendable, Error {
    public enum Code: String, Sendable, CaseIterable {
        case invalidArgument
        case unsupported
        case featureDisabled
        case unavailable
        case protocolMismatch
        case schemaMismatch
        case bootChanged
        case storeReplaced
        case storeNotReady
        case storeBusy
        case storageUnavailable
        case keyUnavailable
        case identityUnknown
        case identityDisabled
        case conflict
        case idempotencyConflict
        case notFound
        case notAuthorized
        case quotaExceeded
        case sizeLimit
        case payloadUnavailable
        case payloadCorrupt
        case cursorExpired
        case snapshotTooLarge
        case dependencyFailed
        case deadlineExceeded
        case interrupted
        case cancelled
        case remoteRejected
        case transportUnavailable
        case protocolFailure
        case outcomeUnknown
    }

    /// Whether/how a command may be retried.
    public enum Retry: String, Sendable {
        case never
        case afterStateChange
        case afterDelay
    }

    public let code: Code
    public let field: String?
    public let retry: Retry
    public let retryAfterMs: NonNegative?
    public let message: String?   // human diagnostic; never branch on its text

    public init(code: Code, field: String? = nil, retry: Retry = .never,
                retryAfterMs: NonNegative? = nil, message: String? = nil) {
        self.code = code
        self.field = field
        self.retry = retry
        self.retryAfterMs = retryAfterMs
        self.message = message
    }

    // Common constructors
    public static func invalidArgument(_ field: String, _ msg: String) -> NodeError {
        NodeError(code: .invalidArgument, field: field, retry: .never, message: msg)
    }
    public static func idempotencyConflict(_ cmd: CommandID) -> NodeError {
        NodeError(code: .idempotencyConflict, field: "commandID", retry: .never,
                  message: "commandID \(cmd.wire) already staged with a different canonical body")
    }
    public static func storeReplaced() -> NodeError {
        NodeError(code: .storeReplaced, retry: .afterStateChange,
                  message: "store epoch changed; stage under the current epoch")
    }
    public static func identityUnknown(_ id: IdentityID) -> NodeError {
        NodeError(code: .identityUnknown, field: "scope.identityID", retry: .afterStateChange,
                  message: "unknown identity \(id.wire)")
    }
}
