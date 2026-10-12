//
//  OutboxQueue.swift
//  Columba Shared (compiled into BOTH ColumbaApp and ColumbaNetworkExtension)
//
//  Track A5c — the durable App-Group outbox for the Model B send path.
//
//  Under Model B the app composes outbound LXMF messages but does NOT own a
//  local node — it marshals each send to the NE over `ProxyIPC`
//  (`ProxyRnsBackend.sendLxmfMessage`). When the NE is stopped / unreachable that
//  round-trip fails, and without persistence the message would be silently
//  dropped. This file is the durable buffer that prevents that loss:
//
//    • ENQUEUE (app side, `ProxyRnsBackend`): on an IPC failure (nil reply, or the
//      NE answering `.error` / `.unsupported`, i.e. the NE did NOT accept the
//      send) the proxy appends an `OutboxEntry` here and returns optimistically so
//      the UI shows the message pending instead of failed.
//
//    • DRAIN (NE side, `PythonNodeEngine.replayOutbox` at node start): once the
//      in-NE Python node is fully up (transport + router + delivery destination),
//      it drains the queue and replays each entry through `lxmfSend(...)`, which
//      marshals into `rns_bridge.send_opportunistic`. The send is then packed +
//      signed + queued by the Python LXMF layer exactly as a live IPC send would
//      have been.
//
//  ── DURABILITY MODEL ─────────────────────────────────────────────────────────
//  This MIRRORS `SharedFrameQueue` exactly: an append-only file in the App-Group
//  container, each record length-framed (`[4-byte big-endian length][payload]`),
//  guarded by a POSIX `flock`-style advisory lock on a sibling `.lock` file so the
//  app (appending) and the NE (draining) never corrupt the file when they touch it
//  concurrently. The payload here is the JSON encoding of one `OutboxEntry` (vs.
//  `SharedFrameQueue`'s raw frame bytes + interface tag). `drainAll()` is the
//  read-all-and-clear analogue of `readAllAndClear()`.
//
//  ── COLLISION RULE (HARD) ────────────────────────────────────────────────────
//  This file imports ONLY Foundation. It is linked into BOTH targets (like
//  `SharedFrameQueue` / `ExtensionDiagLog` / `AppGroupPaths` / `ProxyIPC`), so it
//  MUST NOT pull in RNSAPI / ReticulumSwift / LXMFSwift — none of which are even
//  linked into the NE. An `OutboxEntry` therefore carries ONLY already-serialized
//  scalars / `Data` (the same shape `ProxyRequest.lxmfSend` crosses the seam with),
//  never a protocol object. The enqueue site (`ProxyRnsBackend`, imports RNSAPI
//  only) and the drain site (`PythonNodeEngine`, imports Foundation/Security only)
//  both keep their own import sets; this Foundation-only seam is what lets them
//  share the queue without either gaining the other's imports.
//

import Foundation

// MARK: - OutboxQueue

/// Durable App-Group queue of pending outbound LXMF sends. The app appends on an
/// IPC failure; the NE drains (read-all-and-clear) once its node is up.
///
/// Direct structural mirror of `SharedFrameQueue`: a length-framed append-only
/// file in the App-Group container, made thread- AND process-safe by a POSIX
/// advisory lock on a sibling `.lock` file. The only differences are that each
/// record's payload is the JSON of one `OutboxEntry` (so there is no per-record
/// interface tag, hence a 4-byte header rather than 5) and that the read API is
/// named `drainAll()` and returns `[OutboxEntry]`.
///
/// `@unchecked Sendable` for the same reason as `SharedFrameQueue`: the only stored
/// state is the immutable `fileURL`; all mutation is serialized under the file
/// lock.
public final class OutboxQueue: @unchecked Sendable {

    // MARK: - Constants

    /// Default file name in the App-Group container holding the durable outbox.
    public static let defaultFileName = "outbox"

    /// Header size: 4 bytes big-endian length (no interface tag, unlike
    /// `SharedFrameQueue`'s 5-byte header).
    private static let headerSize = 4

    // MARK: - Properties

    /// Path to the outbox file in the shared container.
    private let fileURL: URL

    // MARK: - Initialization

    /// Create the outbox queue in the given App-Group container.
    ///
    /// - Parameters:
    ///   - appGroupIdentifier: The App-Group identifier (defaults to the shared
    ///     `appGroupIdentifier` constant both targets already use).
    ///   - name: File name within the container. Defaults to `defaultFileName`
    ///     (`"outbox"`). Each name gets its own backing file + its own `.lock` file.
    public init(appGroupIdentifier: String = appGroupIdentifier, name: String = OutboxQueue.defaultFileName) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            // Fallback to tmp if the App-Group container is unavailable (shouldn't
            // happen in production — same fallback posture as `SharedFrameQueue`).
            self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            return
        }
        self.fileURL = containerURL.appendingPathComponent(name)
    }

    // MARK: - Public API

    /// Append one pending send to the durable outbox (called by the app on an IPC
    /// failure). Thread- and process-safe via the POSIX file lock; concurrent
    /// appenders are serialized by the lock.
    ///
    /// JSON-encodes `entry`, frames it with a 4-byte big-endian length, and writes
    /// it to the end of the file. An entry that fails to encode (effectively
    /// unreachable — `OutboxEntry` is all-Codable) is dropped silently rather than
    /// corrupting the stream.
    public func append(_ entry: OutboxEntry) {
        guard let payload = try? JSONEncoder().encode(entry) else { return }

        let length = UInt32(payload.count)
        var header = Data(count: Self.headerSize)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        withFileLock {
            let fh: FileHandle
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = handle
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = handle
            }
            fh.seekToEndOfFile()
            fh.write(header)
            fh.write(payload)
            fh.closeFile()
        }
    }

    /// Read every pending entry and clear the queue (called by the NE once its node
    /// is up). Atomically reads all records and truncates the file under the lock,
    /// so an `append` racing the drain either lands fully before the read or fully
    /// after the truncate — never half-consumed.
    ///
    /// Malformed / truncated tail records are skipped (parsing stops), matching
    /// `SharedFrameQueue.readAllAndClear`; a record whose JSON fails to decode is
    /// skipped individually but parsing continues past it.
    ///
    /// - Returns: All decoded entries in append order, possibly empty.
    public func drainAll() -> [OutboxEntry] {
        withFileLock {
            let entries = readAllLocked()
            // Truncate the file (read-all-and-clear).
            try? Data().write(to: fileURL, options: .atomic)
            return entries
        }
    }

    /// Non-destructive read: decode every entry in append order WITHOUT clearing
    /// the file. Used by the outbox-replay path so that a replay can send entries
    /// and only prune the ones it confirms as sent (P1 #3: a read-all-and-clear
    /// here would drop entries the replay never reached if the extension stops
    /// mid-loop). Concurrent app appends are preserved because the read is a plain
    /// decode with no write.
    public func pending() -> [OutboxEntry] {
        withFileLock {
            readAllLocked()
        }
    }

    /// Atomically drop every entry for which `keep` returns false, rewriting the
    /// file with the survivors in original order. The read-filter-rewrite happens
    /// in ONE locked pass, so an entry the app appends while this runs is not
    /// clobbered (the filter re-reads the fresh stream). Returns the number of
    /// entries removed.
    @discardableResult
    public func remove(where keep: (OutboxEntry) -> Bool) -> Int {
        withFileLock {
            let all = readAllLocked()
            let survivors = all.filter(keep)
            try? writeLocked(survivors)
            return all.count - survivors.count
        }
    }

    /// Decode every record in `data` (or the file) into `[OutboxEntry]` in append
    /// order. Caller must hold the file lock. Malformed / truncated tail records
    /// stop parsing; a record whose JSON fails to decode is skipped individually
    /// but parsing continues past it.
    private func readAllLocked() -> [OutboxEntry] {
        var entries: [OutboxEntry] = []
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return entries
        }

        var offset = 0
        while offset + Self.headerSize <= data.count {
            let length = Int(
                (UInt32(data[offset]) << 24) |
                (UInt32(data[offset + 1]) << 16) |
                (UInt32(data[offset + 2]) << 8) |
                UInt32(data[offset + 3])
            )
            offset += Self.headerSize

            guard offset + length <= data.count else {
                // Truncated trailing record - stop parsing.
                break
            }

            let recordData = data[offset..<(offset + length)]
            if let entry = try? JSONDecoder().decode(OutboxEntry.self, from: Data(recordData)) {
                entries.append(entry)
            }
            // A record that fails to decode is skipped, but we still advance by
            // its framed length so the rest of the stream stays parseable.
            offset += length
        }
        return entries
    }

    /// Atomically rewrite the file with exactly `entries` (length-framed, JSON),
    /// replacing any prior contents. Caller must hold the file lock.
    private func writeLocked(_ entries: [OutboxEntry]) throws {
        var out = Data()
        for entry in entries {
            guard let payload = try? JSONEncoder().encode(entry) else { continue }
            let length = UInt32(payload.count)
            var header = Data(count: Self.headerSize)
            header[0] = UInt8((length >> 24) & 0xFF)
            header[1] = UInt8((length >> 16) & 0xFF)
            header[2] = UInt8((length >> 8) & 0xFF)
            header[3] = UInt8(length & 0xFF)
            out.append(header)
            out.append(payload)
        }
        try out.write(to: fileURL, options: .atomic)
    }

    /// True if the outbox file exists and is non-empty, without reading it.
    /// Mirrors `SharedFrameQueue.hasFrames`.
    public var hasEntries: Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size > 0
    }

    // MARK: - File Locking

    /// Execute a closure while holding a POSIX exclusive lock on a sibling `.lock`
    /// file. Identical strategy to `SharedFrameQueue.withFileLock` — a separate lock
    /// file keeps the advisory lock off the data file itself, and a separate `.lock`
    /// per queue name means the outbox never contends with the frame queues.
    private func withFileLock<T>(_ body: () -> T) -> T {
        let lockPath = fileURL.path + ".lock"

        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }

        let lockFd = Darwin.open(lockPath, O_RDWR)
        guard lockFd >= 0 else {
            // Can't open the lock file - run without the lock (best effort), same
            // as `SharedFrameQueue`.
            return body()
        }

        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        _ = fcntl(lockFd, F_SETLKW, &fl)

        let result = body()

        fl.l_type = Int16(F_UNLCK)
        _ = fcntl(lockFd, F_SETLK, &fl)
        Darwin.close(lockFd)
        return result
    }
}
