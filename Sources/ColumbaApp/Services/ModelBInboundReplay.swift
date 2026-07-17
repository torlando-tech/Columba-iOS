#if os(iOS)
//
//  ModelBInboundReplay.swift
//  ColumbaApp
//
//  Restores app-side inbound FIELD side-channel processing under Model B.
//
//  In Model B the Network Extension owns LXMF delivery: it persists each inbound
//  message to the shared App-Group GRDB store and posts a Darwin "new message"
//  ping, but it runs NONE of the field side-channel processing (reactions,
//  replies, telemetry → map pin, peer icon, cease) that `IncomingMessageHandler`
//  performs in Model A, where the in-process `LXMRouter` delegate fires per
//  message. `ProxyRnsBackend` emits no `.inbound` BackendEvent, so that handler
//  never runs. Symptom on device: the base message arrives + notifies, but a
//  peer's shared location never renders a pin, an inbound reaction never merges,
//  an inbound reply never threads.
//
//  This driver closes the gap PURELY app-side (no NE / IPC changes): on each
//  Darwin ping (and on start, to catch up on anything delivered while suspended)
//  it scans the shared store for inbound messages it hasn't processed yet and
//  replays each through the SAME `IncomingMessageHandler.handleInbound` — one
//  code path, every field, uniformly. The base message is already persisted (the
//  NE did it), so `handleInbound` only runs the side channels; user notifications
//  are suppressed because the NE already posted them.
//
//  ── Exactly-once, correctly (the Model B counterpart of "the in-process delegate
//     fires once per message", made explicit because delivery crosses the
//     suspendable NE↔app boundary) ──
//    • The scan starts from watermark 0, so messages the NE persisted BEFORE this
//      service started (or before the update shipped) are caught up, not dropped.
//    • It pages each conversation (newest-first) until it crosses the watermark, so
//      a burst larger than one page isn't skipped.
//    • The checkpoint is by OUTCOME: `handleInbound` reports whether its required
//      DB writes succeeded, and a message is only advanced-past on success. A
//      transient failure keeps the message in a durable retry set (fetched by hash
//      next drain, independent of the watermark) so it's neither lost (the
//      watermark would skip it) nor head-of-line-blocking (the watermark still
//      advances past it). This matters because a reaction merge is a TOGGLE, not
//      idempotent — re-running an already-applied reaction would undo it.
//    • The watermark, boundary-dedup set, and retry set are persisted as ONE
//      atomic `Checkpoint` blob under a single per-identity key, so a stop between
//      writes can't leave a mixed state (advance the watermark past a failure not
//      yet recorded for retry, or replay a reaction whose boundary hash wasn't
//      saved). Per-identity, so an identity switch can't inherit another identity's
//      checkpoint.
//

import Foundation
import RNSAPI
import os.log

@available(iOS 17.0, *)
@MainActor
public final class ModelBInboundReplay {

    private let repository: MessageRepository
    private let handler: IncomingMessageHandler
    private let observer = NotificationObserver()
    private let logger = Logger(subsystem: "network.columba.Columba", category: "ModelBInboundReplay")

    /// Stable per-identity discriminator (the identity's GRDB path) so checkpoints
    /// don't leak across an identity switch.
    private let scope: String

    /// Max messages processed per drain pass. Bounds work + keeps the first-run
    /// catch-up (watermark 0 → the whole existing inbox) responsive; a remainder
    /// triggers an immediate follow-up pass via `rescanRequested`.
    private static let batchCap = 200
    /// Per-conversation page size when scanning the store.
    private static let pageSize = 200

    private var draining = false
    private var rescanRequested = false

    /// One atomically-persisted checkpoint per identity: the timestamp watermark
    /// (only inbound at/after it are scan candidates), the boundary-dedup set
    /// (SUCCESSFUL hashes sharing the exact watermark timestamp, so we don't
    /// re-touch them every ping), and the retry set (hashes whose required field
    /// processing failed — retried by hash each drain, independent of the
    /// watermark; NOT capped, since an entry below the watermark is reachable ONLY
    /// here and dropping it would permanently lose its update — it stays tiny in
    /// practice, bounded by the inbox, growing only under sustained write failure
    /// where UserDefaults writes fail too).
    private struct Checkpoint: Codable {
        var watermark: Double = 0
        var boundary: [String] = []
        var failed: [String] = []
    }

    private var checkpointKey: String { "modelb_inbound_checkpoint_\(scope)" }

    private func loadCheckpoint() -> Checkpoint {
        guard let data = SharedDefaults.suite.data(forKey: checkpointKey),
              let cp = try? JSONDecoder().decode(Checkpoint.self, from: data) else {
            return Checkpoint()
        }
        return cp
    }

    /// Single write → the whole checkpoint moves atomically (UserDefaults updates
    /// one key's value as a unit), so no partial-state window.
    private func saveCheckpoint(_ cp: Checkpoint) {
        if let data = try? JSONEncoder().encode(cp) {
            SharedDefaults.suite.set(data, forKey: checkpointKey)
        }
    }

    public init(repository: MessageRepository, handler: IncomingMessageHandler, identityScope: String) {
        self.repository = repository
        self.handler = handler
        self.scope = identityScope.isEmpty ? "default" : identityScope
        // Model B: the NE posts the inbound notification on receipt, so the app's
        // replay must not double-notify — it only does field side-channel work.
        handler.suppressUserNotifications = true
    }

    /// Subscribe to the NE's Darwin "new message" ping and do an initial catch-up
    /// pass (for anything delivered while the app was suspended / before start).
    public func start() {
        observer.onNewMessage { [weak self] in
            // Callback may fire off the main thread — hop on.
            Task { @MainActor in self?.requestDrain() }
        }
        requestDrain()
    }

    /// Coalesce bursts of pings into at most one in-flight drain plus one trailing
    /// rescan, so a flurry of arrivals doesn't spawn overlapping scans.
    private func requestDrain() {
        if draining { rescanRequested = true; return }
        Task { @MainActor in await self.drain() }
    }

    private func drain() async {
        draining = true
        defer { draining = false }
        repeat {
            rescanRequested = false
            await drainOnce()
        } while rescanRequested
    }

    private func drainOnce() async {
        var checkpoint = loadCheckpoint()
        // Watermark 0 on first run → full catch-up of everything the NE already
        // persisted (NOT "now", which would drop pending messages). The end state
        // is each peer's latest pin + all reactions/replies applied.
        let watermark = checkpoint.watermark
        let boundary = Set(checkpoint.boundary)
        var failed = Set(checkpoint.failed)

        // Candidates, keyed by hash to dedup the two sources:
        //   • new messages at/after the watermark (minus the boundary dedup), paging
        //     each conversation (store is newest-first) until we cross the watermark
        //     so a burst larger than one page isn't skipped, and
        //   • prior failures to retry, fetched by hash (they may sit BELOW the
        //     watermark, which the scan wouldn't reach).
        var byHash: [String: RNSAPI.LXMessage] = [:]
        do {
            let conversations = try await repository.fetchConversations(limit: 1000)
            for conv in conversations {
                var offset = 0
                pageLoop: while true {
                    let page = try await repository.fetchMessages(for: conv.hash, limit: Self.pageSize, offset: offset)
                    if page.isEmpty { break }
                    for m in page where m.incoming && m.timestamp >= watermark {
                        let hex = Self.hex(m.hash)
                        if boundary.contains(hex) { continue }
                        byHash[hex] = m
                    }
                    // Newest-first: once the oldest row on this page is below the
                    // watermark, every older page is too.
                    if let oldest = page.last, oldest.timestamp < watermark { break pageLoop }
                    if page.count < Self.pageSize { break }
                    offset += page.count
                }
            }
            for hex in failed where byHash[hex] == nil {
                if let data = Data(hexString: hex),
                   let m = try await repository.getMessage(id: data), m.incoming {
                    byHash[hex] = m
                } else {
                    failed.remove(hex)  // message gone from the store — nothing to retry
                }
            }
        } catch {
            logger.error("Model B inbound drain fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !byHash.isEmpty else {
            // Persist any retry-set prune above as one atomic write.
            checkpoint.failed = Array(failed)
            saveCheckpoint(checkpoint)
            return
        }
        let candidates = byHash.values.sorted { $0.timestamp < $1.timestamp }

        // Bound each pass; a remainder is picked up by an immediate follow-up.
        let batch = Array(candidates.prefix(Self.batchCap))
        let hasMore = candidates.count > batch.count

        var maxTS = watermark
        var succeededAtMax: Set<String> = []
        for m in batch {
            let hex = Self.hex(m.hash)
            // AWAIT completion, and checkpoint by OUTCOME: on success the message is
            // done; on failure (a transient required-write error) keep it in `failed`
            // to retry, but still let the watermark advance past it so it never
            // head-of-line-blocks newer messages.
            let ok = await handler.handleInbound(m).value
            if ok { failed.remove(hex) } else { failed.insert(hex) }
            if m.timestamp > maxTS { maxTS = m.timestamp; succeededAtMax.removeAll() }
            if m.timestamp == maxTS, ok { succeededAtMax.insert(hex) }
        }

        // Boundary dedups only SUCCESSFUL messages sharing the new watermark ts (a
        // failure at the boundary must stay retryable via `failed`, not deduped).
        var newBoundary = succeededAtMax
        if maxTS == watermark { newBoundary.formUnion(boundary) }

        // One atomic write of watermark + boundary + failed together.
        saveCheckpoint(Checkpoint(watermark: maxTS, boundary: Array(newBoundary), failed: Array(failed)))

        logger.info("Model B replay: processed \(batch.count, privacy: .public) inbound message(s); \(failed.count, privacy: .public) pending retry\(hasMore ? " (more queued)" : "")")

        if hasMore { rescanRequested = true }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
