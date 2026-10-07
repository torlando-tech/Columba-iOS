//
//  OutboxReplayCoordinator.swift
//  Columba Shared (compiled into BOTH ColumbaApp and ColumbaNetworkExtension)
//
//  The PURE, unit-testable seam for the durable-outbox recovery + send-response
//  ambiguity fix (architecture review P1 #3 + #6). It composes the two durable
//  pieces:
//
//    - `OutboxQueue`: the app appends a pending send here when the NE did not
//      accept it (IPC failure / .error / .unsupported).
//    - `SentIdStore`: the NE records each send it actually sent, keyed by the
//      app-assigned stable `sendId`.
//
//  `pendingReplays()` is the decision the review wanted instead of an
//  "unconditional drain": drain the queue and return ONLY the entries that still
//  need sending (sendId not yet in the store; a nil-id entry always qualifies).
//  That single check is what stops a lost live reply + outbox replay from
//  double-sending, because the NE records the id the moment it sends.
//
//  ── COLLISION RULE (HARD) ───────────────────────────────────────────────────
//  Foundation ONLY (both targets). It references no RNSAPI / ReticulumSwift /
//  LXMFSwift and performs no send itself - the caller (the NE) executes the
//  actual replay through its Python send path and calls `markSent` on success.
//
import Foundation

public struct OutboxReplayCoordinator: @unchecked Sendable {

    public let queue: OutboxQueue
    public let sentIds: SentIdStore

    /// Default: both backings live in the shared App-Group container (the
    /// production configuration).
    public init(appGroupIdentifier: String = appGroupIdentifier) {
        self.queue = OutboxQueue(appGroupIdentifier: appGroupIdentifier)
        self.sentIds = SentIdStore(appGroupIdentifier: appGroupIdentifier)
    }

    /// Explicit backings (used by the NE and by unit tests to point at a
    /// temp file).
    public init(queue: OutboxQueue, sentIds: SentIdStore) {
        self.queue = queue
        self.sentIds = sentIds
    }

    /// Drain the outbox and return the entries that still need replay, in append
    /// order. An entry is replayed only when it carries no stable id (pre-migration
    /// / unknown) OR its id is not yet recorded in the sent-id store. Entries whose
    /// id is already sent are dropped (the NE delivered them; a lost reply that led
    /// the app to re-enqueue the SAME id is the double-send this prevents).
    ///
    /// The queue is cleared as part of the drain (read-all-and-clear); entries we
    /// choose not to replay are intentionally discarded (they are already sent), so
    /// the queue cannot refill with already-delivered messages.
    public func pendingReplays() -> [OutboxEntry] {
        queue.drainAll().filter { entry in
            guard let sendId = entry.sendId else { return true }
            return !sentIds.contains(sendId)
        }
    }

    /// Record that a send (by stable id) was actually sent by the NE. Call this
    /// AFTER the send succeeds (or is accepted), so a later drain/restart does not
    /// re-send it. Idempotent. A nil id is a no-op (nothing to dedup against).
    public func markSent(_ sendId: String?) {
        guard let sendId, !sendId.isEmpty else { return }
        sentIds.record(sendId)
    }
}
