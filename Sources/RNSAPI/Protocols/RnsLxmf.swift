//
//  RnsLxmf.swift
//  RNSAPI
//
//  LXMF messaging facet of the backend seam — iOS analog of Android Columba's
//  `rns-api/RnsLxmf`. Outbound LXMF fields cross the seam as TYPED parameters
//  (image / attachments / icon / reply) plus a raw `extraFields` escape hatch,
//  rather than a `[UInt8: Any]` map (which isn't `Sendable`). The backend
//  assembles the on-wire LXMF field map from these, using the canonical
//  `LxmfFields` IDs so the encoding matches Sideband/upstream.
//

import Foundation

/// A file attachment carried in `FIELD_FILE_ATTACHMENTS` (0x05) as `[name, bytes]`.
public struct RnsFileAttachment: Sendable, Equatable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public protocol RnsLxmf: AnyObject, Sendable {

    /// Send an LXMF message. Structured fields are passed typed; `extraFields`
    /// carries any pre-encoded raw field bytes (e.g. custom metadata) keyed by
    /// `LxmfFields` ID. The backend builds the wire field map and routes per
    /// `method`. `replyToMessageHashHex` → `FIELD_REPLY_HASH` (0x30) and
    /// `replyQuotedContent` → `FIELD_REPLY_QUOTE` (0x31), matching Android's
    /// canonical reply encoding (not the legacy 0x10 dict).
    @discardableResult
    func sendLxmfMessage(
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
    ) async throws -> SendOutcome

    /// Send a tap-back reaction via canonical `FIELD_REACTION` (0x40) on an
    /// otherwise-empty message: `{0x00: targetHashBytes, 0x01: emojiUTF8}`.
    @discardableResult
    func sendReaction(
        destHashHex: String,
        targetMessageHashHex: String,
        emoji: String
    ) async throws -> SendOutcome

    /// Set / clear the outbound LXMF propagation node (empty hex clears).
    @discardableResult
    func setPropagationNode(destHashHex: String, stampCost: Int) async throws -> Bool

    /// Blocking sync from the configured propagation node.
    func propagationSync(timeout: TimeInterval) async throws -> PropagationSyncResult
}

// Ergonomic overloads (protocol requirements can't carry default arguments).
public extension RnsLxmf {
    @discardableResult
    func sendLxmfMessage(destHashHex: String, content: String,
                         method: LXDeliveryMethod = .opportunistic) async throws -> SendOutcome {
        try await sendLxmfMessage(
            destHashHex: destHashHex, content: content, method: method,
            imageData: nil, imageFormat: nil, fileAttachments: nil, iconAppearance: nil,
            replyToMessageHashHex: nil, replyQuotedContent: nil, extraFields: nil
        )
    }

    @discardableResult
    func setPropagationNode(destHashHex: String) async throws -> Bool {
        try await setPropagationNode(destHashHex: destHashHex, stampCost: 0)
    }

    func propagationSync() async throws -> PropagationSyncResult {
        try await propagationSync(timeout: 60.0)
    }
}
