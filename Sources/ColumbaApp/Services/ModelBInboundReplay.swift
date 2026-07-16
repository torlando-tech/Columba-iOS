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
//  Field processing is idempotent (reaction frames self-delete after merge;
//  reply/icon/telemetry/cease set-or-render the same value), so the only cost of
//  re-touching a boundary message is a redundant no-op — never duplication or
//  loss. A small persisted boundary set dedups messages sharing the exact
//  watermark timestamp so we don't churn on them every ping.
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
        // persisted (NOT "now", which would drop pending messages). Idempotent
        // processing makes replaying history safe; the end state is each peer's
        // latest pin + all reactions/replies applied.
        let watermark = defaults.double(forKey: watermarkKey)
        let boundary = Set(defaults.stringArray(forKey: boundaryKey) ?? [])

        // Gather candidates across conversations, paging each (store is
        // newest-first) until we cross the watermark, so a burst beyond one page
        // isn't skipped.
        var candidates: [RNSAPI.LXMessage] = []
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
                        candidates.append(m)
                    }
                    // Newest-first: once the oldest row on this page is below the
                    // watermark, every older page is too.
                    if let oldest = page.last, oldest.timestamp < watermark { break pageLoop }
                    if page.count < Self.pageSize { break }
                    offset += page.count
                }
            }
        } catch {
            logger.error("Model B inbound drain fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !candidates.isEmpty else { return }
        candidates.sort { $0.timestamp < $1.timestamp }

        // Bound each pass; a remainder is picked up by an immediate follow-up.
        let batch = Array(candidates.prefix(Self.batchCap))
        let hasMore = candidates.count > batch.count

        var maxTS = watermark
        for m in batch {
            // AWAIT completion before checkpointing: if the process is suspended /
            // killed after this returns, the message is fully handled and the
            // advanced watermark below is safe.
            await handler.handleInbound(m).value
            maxTS = max(maxTS, m.timestamp)
        }

        // Boundary = processed hashes sharing the new watermark timestamp (the only
        // ones a subsequent `>= watermark` scan re-surfaces). Preserve the prior
        // boundary only if the watermark didn't advance past it.
        var newBoundary = Set(batch.filter { $0.timestamp == maxTS }.map { Self.hex($0.hash) })
        if maxTS == watermark { newBoundary.formUnion(boundary) }
        defaults.set(maxTS, forKey: watermarkKey)
        defaults.set(Array(newBoundary), forKey: boundaryKey)

        logger.info("Model B replay: processed \(batch.count, privacy: .public) inbound message(s) for field side-channels\(hasMore ? " (more pending)" : "")")

        if hasMore { rescanRequested = true }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
