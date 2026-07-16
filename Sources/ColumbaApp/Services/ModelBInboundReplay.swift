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
//  Darwin ping it scans the shared store for inbound messages it hasn't processed
//  yet and replays each through the SAME `IncomingMessageHandler.handleInbound` —
//  one code path, every field, uniformly. The base message is already persisted
//  (the NE did it), so `handleInbound` only runs the side channels; user
//  notifications are suppressed because the NE already posted them.
//
//  Exactly-once: a persisted timestamp watermark (`SharedDefaults`) plus an
//  in-memory boundary dedup keyed by message hash. The watermark is seeded to
//  "now" on first run so pre-existing history isn't reprocessed. This is the
//  Model B counterpart of the in-process "delegate fires once per message"
//  guarantee — made explicit because delivery crosses the suspendable NE↔app
//  boundary (the app may be asleep at receipt; it catches up on next launch).
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

    /// App-Group-persisted "last processed inbound timestamp". Only inbound
    /// messages at/after this are candidates; it advances monotonically.
    private static let watermarkKey = "modelb_inbound_watermark_ts"
    /// Set once the watermark has been seeded (so first run skips history).
    private static let seededKey = "modelb_inbound_replay_seeded"

    /// Hash→timestamp of messages processed AT the current watermark boundary.
    /// The next `>= watermark` scan re-surfaces exactly these (ties on the
    /// boundary timestamp); this dedups them. Pruned to `ts >= watermark` after
    /// each drain, so it stays tiny (everything below the watermark can never be
    /// re-fetched).
    private var boundaryProcessed: [String: Double] = [:]

    private var draining = false
    private var rescanRequested = false

    public init(repository: MessageRepository, handler: IncomingMessageHandler) {
        self.repository = repository
        self.handler = handler
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

        // First run: seed the watermark to "now" so we don't replay the entire
        // pre-existing inbox (which would re-render every historical pin and,
        // worse, re-merge historical reactions). Only messages arriving AFTER the
        // fix ships are processed.
        if !defaults.bool(forKey: Self.seededKey) {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.watermarkKey)
            defaults.set(true, forKey: Self.seededKey)
            return
        }

        let watermark = defaults.double(forKey: Self.watermarkKey)

        // Gather candidate inbound messages across conversations. `fetchMessages`
        // is per-conversation (no cross-conversation query on the store), but a
        // device has few conversations and the Darwin ping is per-arrival, so the
        // recent slice is small.
        var candidates: [RNSAPI.LXMessage] = []
        do {
            let conversations = try await repository.fetchConversations(limit: 500)
            for conv in conversations {
                let msgs = try await repository.fetchMessages(for: conv.hash, limit: 50)
                for m in msgs where m.incoming && m.timestamp >= watermark {
                    let hex = Self.hex(m.hash)
                    if boundaryProcessed[hex] != nil { continue }
                    candidates.append(m)
                }
            }
        } catch {
            logger.error("Model B inbound drain fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !candidates.isEmpty else { return }
        candidates.sort { $0.timestamp < $1.timestamp }

        var maxTS = watermark
        for m in candidates {
            handler.handleInbound(m)
            boundaryProcessed[Self.hex(m.hash)] = m.timestamp
            maxTS = max(maxTS, m.timestamp)
        }
        defaults.set(maxTS, forKey: Self.watermarkKey)
        // Keep only boundary hashes (ts >= new watermark); the rest can never be
        // re-fetched by the next `>= watermark` scan.
        boundaryProcessed = boundaryProcessed.filter { $0.value >= maxTS }

        logger.info("Model B replay: processed \(candidates.count, privacy: .public) inbound message(s) for field side-channels")
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
