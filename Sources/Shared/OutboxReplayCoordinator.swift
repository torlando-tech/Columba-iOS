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

    /// Read the outbox and return the entries that still need replay, in append
    /// order, WITHOUT clearing the file (P1 #3). An entry is replayed only when it
    /// carries no stable id (pre-migration / unknown) OR its id is not yet recorded
    /// in the sent-id store. Entries whose id is already sent are NOT replayed -
    /// that single check is what stops a lost live reply + outbox replay from
    /// double-sending, because the NE records the id the moment it sends.
    ///
    /// The queue is NOT cleared here: `replayOutbox` sends each entry and then
    /// calls `commitSent(_:)` to prune only the entries it confirmed as sent. A
    /// read-all-and-clear here would drop the entries the replay never reaches if
    /// the extension stops mid-loop, so every pending send stays on disk until it
    /// is either confirmed sent or (re)attempted on the next pass.
    public func pendingReplays() -> [OutboxEntry] {
        queue.pending().filter { entry in
            guard let sendId = entry.sendId else { return true }
            return !sentIds.contains(sendId)
        }
    }

    /// After `replayOutbox` has sent its batch, prune the queue down to the
    /// entries that are NOT yet confirmed sent (the failed / not-yet-attempted
    /// ones). This is the durability half of P1 #3: a send that succeeded is
    /// removed now (and its id is in the store), but a send that failed STAYS on
    /// disk so the next replay (or the next start) retries it instead of it
    /// vanishing with the process.
    public func commitSent() {
        _ = queue.remove { entry in
            guard let sendId = entry.sendId else { return true }
            return !sentIds.contains(sendId)
        }
    }

    /// Record that a send (by stable id) was actually sent by the NE. Call this
    /// AFTER the send succeeds (or is accepted), so a later drain/restart does not
    /// re-send it. Idempotent. A nil id is a no-op (nothing to dedup against).
    ///
    /// Returns whether the id is now durably recorded. `true` for a nil id (nothing
    /// to persist) and when the append succeeds; `false` when a real id could not be
    /// persisted (file open/write failure). The send path uses this to surface a
    /// lost-dedup (see `NEPythonRNS.lxmfSend`) instead of silently claiming the
    /// send is safe from a lost-reply re-enqueue.
    @discardableResult
    public func markSent(_ sendId: String?) -> Bool {
        guard let sendId, !sendId.isEmpty else { return true }
        return sentIds.record(sendId)
    }
}
