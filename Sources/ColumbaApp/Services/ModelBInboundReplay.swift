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
//    • The checkpoint (a per-identity timestamp watermark) advances only AFTER a
//      message's field work has actually COMPLETED (`await handleInbound(_).value`),
//      so a suspend/terminate mid-flight resumes rather than skips it.
//    • The scan starts from watermark 0, so messages the NE persisted BEFORE this
//      service started (or before the update shipped) are caught up, not dropped.
//    • It pages each conversation until it crosses the watermark, so a burst larger
//      than one page isn't skipped.
//    • Keys are per-identity, so an identity switch can't inherit another
//      identity's watermark and filter out that identity's pending messages.
//    • The checkpoint is by OUTCOME: `handleInbound` reports whether its required
//      DB writes succeeded, and a message is only advanced-past on success. A
//      transient failure keeps the message in a durable retry set (fetched by hash
//      next drain, independent of the watermark) so it's neither lost nor
//      head-of-line-blocking. This matters because a reaction merge is a TOGGLE,
//      not idempotent — re-running an already-applied reaction would undo it, so
//      "did it actually apply?" must gate the checkpoint. A small boundary set
//      dedups successful messages sharing the exact watermark timestamp so we
//      don't re-touch them every ping.
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

    /// Stable per-identity discriminator (the identity hash hex) so checkpoints
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

    private var watermarkKey: String { "modelb_inbound_watermark_ts_\(scope)" }
    private var boundaryKey: String { "modelb_inbound_boundary_hashes_\(scope)" }
    /// Hashes whose REQUIRED field processing failed (transient DB error). Retried
    /// on every drain, fetched by hash independently of the watermark — so a
    /// failure is neither lost (the watermark would skip it) nor head-of-line
    /// blocking (the watermark still advances past it). Cleared on success or when
    /// the message is gone from the store. NOT capped: entries below the watermark
    /// are only reachable via this set, so dropping one would permanently lose its
    /// field update. In practice it stays tiny — failures are rare transient DB
    /// errors that clear on the next retry; the only thing that grows it is a
    /// sustained write failure (e.g. a full disk), under which UserDefaults writes
    /// fail too and the app is already degraded. It is bounded by the inbox size
    /// regardless.
    private var failedKey: String { "modelb_inbound_failed_hashes_\(scope)" }

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
        let defaults = SharedDefaults.suite
        // Watermark 0 on first run → full catch-up of everything the NE already
        // persisted (NOT "now", which would drop pending messages). The end state
        // is each peer's latest pin + all reactions/replies applied.
        let watermark = defaults.double(forKey: watermarkKey)
        let boundary = Set(defaults.stringArray(forKey: boundaryKey) ?? [])
        var failed = Set(defaults.stringArray(forKey: failedKey) ?? [])

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
            defaults.set(Array(failed), forKey: failedKey)  // persist any prune above
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
        defaults.set(maxTS, forKey: watermarkKey)
        defaults.set(Array(newBoundary), forKey: boundaryKey)
        defaults.set(Array(failed), forKey: failedKey)

        logger.info("Model B replay: processed \(batch.count, privacy: .public) inbound message(s); \(failed.count, privacy: .public) pending retry\(hasMore ? " (more queued)" : "")")

        if hasMore { rescanRequested = true }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
