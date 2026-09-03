//
//  CallHistoryModels.swift
//  ColumbaApp
//
//  Call-history persistence record (GRDB) and read model. Kept in one file with
//  the pure formatters' `CallOutcome` / `CallHistoryDirection` (Task 1) so the
//  feature's types have a single home. No LXMFSwift import (GRDB only).
//

import Foundation
import GRDB

/// GRDB-backed persistent row for one call attempt. One row per accepted attempt,
/// identified by `callAttemptId`. Scoped by `localIdentityHash` (identity-scoped,
/// like the Android Room entity).
public struct CallHistoryEntity: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var callAttemptId: String
    public var localIdentityHash: String
    public var remoteIdentityHash: String
    public var direction: String            // "incoming" | "outgoing"
    public var peerDisplayNameSnapshot: String?
    public var codecProfileCode: Int?
    public var attemptedAt: Date
    public var ringingAt: Date?
    public var connectedAt: Date?
    public var endedAt: Date?
    public var outcome: String?             // CallOutcome.rawValue
    public var failureReason: String?

    public static let databaseTableName = "columba_call_history"

    public mutating func didInsert(_ inserted: InsertionSuccess) {}

    public init(callAttemptId: String, localIdentityHash: String, remoteIdentityHash: String,
                direction: CallHistoryDirection, peerDisplayNameSnapshot: String?,
                codecProfileCode: Int?, attemptedAt: Date) {
        self.callAttemptId = callAttemptId
        self.localIdentityHash = localIdentityHash
        self.remoteIdentityHash = remoteIdentityHash
        self.direction = direction.rawValue
        self.peerDisplayNameSnapshot = peerDisplayNameSnapshot
        self.codecProfileCode = codecProfileCode
        self.attemptedAt = attemptedAt
    }
}

/// Read-only record presented to the UI.
///
/// ENRICHMENT LIVES AT THE VIEW LAYER, NOT HERE. Do NOT join `conversations` in
/// the repository: (1) the in-memory test DB only creates `columba_call_history`,
/// so a JOIN throws "no such table"; (2) `conversations.destination_hash` is a
/// BLOB (16-byte `Data`) while we store TEXT hex, so the key wouldn't match; (3)
/// the display column is `display_name`, not `peer_name`. Instead the view (Task
/// 4) resolves the live display name + profile icon via
/// `MessageRepository.fetchConversations(for:)` and falls back to
/// `peerDisplayNameSnapshot`, then `CallHistoryFormatting.peerName`. This keeps
/// the repository a pure, GRDB-only, conversations-independent module (YAGNI) and
/// still gives Android parity (a rename shows up because the view reads live).
public struct CallHistoryRecord: Identifiable, Hashable, Sendable {
    public let callAttemptId: String
    public let localIdentityHash: String
    public let remoteIdentityHash: String
    public let direction: CallHistoryDirection
    public let peerDisplayNameSnapshot: String?
    public let codecProfileCode: Int?
    public let attemptedAt: Date
    public let ringingAt: Date?
    public let connectedAt: Date?
    public let endedAt: Date?
    public let outcome: CallOutcome?
    public let failureReason: String?

    public var id: String { callAttemptId }

    /// Remote identity hash as raw `Data` (16 bytes) for initiating a call and
    /// rendering the fallback identicon. `remoteIdentityHash` is stored as a
    /// 32-char hex string; this decodes it byte-for-byte.
    ///
    /// Returns `nil` when the stored value is not a valid even-length hex string
    /// (rather than silently zero-filling) so a malformed hash can never produce
    /// a bogus 16-byte blob that dials the wrong number. Call sites treat `nil`
    /// as "invalid — don't dial / use the empty fallback".
    public var remoteIdentityHashData: Data? {
        guard remoteIdentityHash.count == 32 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(16)
        var idx = remoteIdentityHash.startIndex
        while idx < remoteIdentityHash.endIndex {
            let next = remoteIdentityHash.index(idx, offsetBy: 2)
            guard let byte = UInt8(remoteIdentityHash[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return Data(bytes)
    }
}

/// A call-history record enriched with the LIVE conversation display name and
/// profile icon.
///
/// The pure `CallHistoryRecord` deliberately carries no `displayName` / icon
/// fields (see its doc: enrichment lives at the view layer, not the repository).
/// `ChatsViewModel.loadVoiceHistory` resolves each remote identity against the
/// `conversations` table (the same source the Chats Text tab reads) and produces
/// these, so a peer rename or icon change shows up immediately — the stored
/// `peerDisplayNameSnapshot` is only a best-effort fallback for identities that
/// have no conversation row yet.
public struct VoiceCallDisplay: Identifiable, Hashable {
    public let record: CallHistoryRecord
    public let displayName: String?
    public let iconName: String?
    public let iconFgColor: String?
    public let iconBgColor: String?

    public var id: String { record.callAttemptId }

    /// Best-effort peer label: live conversation name → stored snapshot →
    /// "Peer XXXXXXXX" truncated hash (the last step delegates to the pure
    /// formatter so there is a single fallback rule).
    public var peerName: String {
        CallHistoryFormatting.peerName(
            displayName: displayName ?? record.peerDisplayNameSnapshot,
            remoteIdentityHash: record.remoteIdentityHashData ?? Data())
    }

    public init(record: CallHistoryRecord, displayName: String?,
                iconName: String?, iconFgColor: String?, iconBgColor: String?) {
        self.record = record
        self.displayName = displayName
        self.iconName = iconName
        self.iconFgColor = iconFgColor
        self.iconBgColor = iconBgColor
    }
}

/// The Chats subtab. `.text` is the default on a fresh launch (Android parity:
/// a new session returns to Text; the selection is session-scoped, not persisted).
public enum ChatsSegment: String, Sendable, CaseIterable {
    case text
    case voice
}
