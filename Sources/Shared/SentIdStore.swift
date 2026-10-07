//
//  SentIdStore.swift
//  Columba Shared (compiled into BOTH ColumbaApp and ColumbaNetworkExtension)
//
//  Durable idempotent set of outbound send IDs already sent, backing the
//  send-response-ambiguity fix (architecture review P1 #6). The app assigns a
//  stable `sendId` to each logical send and crosses it over IPC (and into the
//  durable outbox fallback); the NE consults this store before (re)sending so a
//  lost live reply followed by an outbox replay cannot double-send the same
//  message.
//
//  ── WHY DURABLE ─────────────────────────────────────────────────────────────
//  A send that succeeds in the NE and is `markSent` must STAY recorded across an
//  NE restart (jetsam / tunnel relaunch). If the record were process-local, a
//  restart after a lost reply would replay a send the NE already delivered.
//  Durability in the shared App-Group container (where the outbox lives) is what
//  makes the dedup survive process boundaries.
//
//  ── COLLISION RULE (HARD) ───────────────────────────────────────────────────
//  Foundation ONLY (linked into both targets, so no RNSAPI / ReticulumSwift /
//  LXMFSwift). One sendId is a lowercase-hex/uuid string, written as a
//  length-framed record (same shape as `SharedFrameQueue` / `OutboxQueue`).
//
//  ── IDEMPOTENT RECORD ───────────────────────────────────────────────────────
//  `record(_:)` is idempotent and concurrency-safe (advisory file lock + a
//  contains-check under the lock): recording an already-known id is a no-op, so
//  the store stays a set even if the app and NE touch it, or a replay re-records
//  an id. The file is append-only (replay-able to rebuild the set); entries are
//  never pruned (a message is only ever sent once per id, so the set is bounded
//  by the count of distinct sends - see the note in `OutboxEntry.sendId`).
//
import Foundation

public final class SentIdStore: @unchecked Sendable {

    /// Default file name in the App-Group container.
    public static let defaultFileName = "sent-ids"

    /// Header: 4-byte big-endian UTF-8 length (the record is the id string).
    private static let headerSize = 4

    private let fileURL: URL

    /// Upper bound on recorded ids. When the store exceeds it, the oldest
    /// (least recent) ids are pruned so the file + the in-memory set stay
    /// bounded (a long-running NE node would otherwise grow them without
    /// limit). The cap is high enough that an id is still recorded long after
    /// its lost-reply re-enqueue window has passed, so pruning does not weaken
    /// the dedup guarantee in any realistic timeline.
    private let maxCapacity: Int
    /// The set of recorded ids, cached in memory so `contains`/`record` are
    /// O(1) instead of scanning the whole file on every send (P1 #12: each
    /// send previously scanned the file twice, once in `contains` and once in
    /// `record`, so send latency grew unboundedly with history). Refreshed from
    /// disk whenever the file size changes (catches an external append), so the
    /// cache can never be stale relative to the durable file.
    private var cachedIds: Set<Data> = []
    private var cachedFileBytes: Int = -1
    private var cacheLoaded = false

    /// Default capacity cap: 10_000 ids (~500 KB of 36-char uuids).
    public static let defaultMaxCapacity = 10_000

    /// Create the store in the App-Group container, falling back to a tmp file
    /// when the container is unavailable (unsigned builds / unit tests). The
    /// fallback is intentional so the dedup logic stays unit-testable on the
    /// simulator (the app group is not present there).
    public init(appGroupIdentifier: String = appGroupIdentifier, name: String = SentIdStore.defaultFileName, maxCapacity: Int = SentIdStore.defaultMaxCapacity) {
        self.maxCapacity = maxCapacity
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            self.fileURL = containerURL.appendingPathComponent(name)
        } else {
            self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        }
    }

    // MARK: Test-only initializer

    /// Back the store with an explicit temporary file (unit tests), sidestepping
    /// the App-Group container which is absent on the simulator.
    init(tempFileURL: URL, maxCapacity: Int = SentIdStore.defaultMaxCapacity) {
        self.fileURL = tempFileURL
        self.maxCapacity = maxCapacity
    }

    // MARK: API

    /// Record a sent id. Idempotent: a known id is a no-op. Concurrency-safe via
    /// the advisory file lock (the contains-check and append run under it).
    ///
    /// Returns whether the id is now durably recorded. `false` only when the id
    /// was NOT already present AND the append failed (file could not be created /
    /// opened / written). The send path relies on this: a send whose id could not
    /// be persisted must be reported as not-committed, so a lost reply leads the
    /// app to re-enqueue (retried) rather than the send being treated as delivered
    /// and silently lost on the next drain (double-send / loss).
    ///
    /// P1 #12: the contains-check consults the in-memory cache (O(1)) and the
    /// append keeps the store bounded by `maxCapacity` (pruning the oldest ids).
    @discardableResult
    public func record(_ id: String) -> Bool {
        let payload = Data(id.utf8)
        guard !payload.isEmpty else { return true }
        let length = UInt32(payload.count)
        var header = Data(count: Self.headerSize)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        var recorded = true
        withFileLock {
            ensureCacheLocked()
            // Idempotency: already recorded is a success (keeps the file a set).
            if cachedIds.contains(payload) { return }
            let fh: FileHandle
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let h = try? FileHandle(forWritingTo: fileURL) else { recorded = false; return }
                fh = h
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                guard let h = try? FileHandle(forWritingTo: fileURL) else { recorded = false; return }
                fh = h
            }
            fh.seekToEndOfFile()
            fh.write(header)
            fh.write(payload)
            fh.closeFile()
            cachedIds.insert(payload)
            cachedFileBytes += header.count + payload.count
            // P1 #12: keep the store bounded by pruning the oldest ids.
            if cachedIds.count > maxCapacity {
                pruneLocked()
            }
        }
        return recorded
    }

    /// True if the id has been recorded (already sent).
    public func contains(_ id: String) -> Bool {
        withFileLock {
            ensureCacheLocked()
            return cachedIds.contains(Data(id.utf8))
        }
    }

    // MARK: Cache + pruning

    /// Ensure the in-memory id set is current with the file (P1 #12). Refreshes
    /// when the file size differs from the cached byte count (an external
    /// append) or on first use. Caller must hold the file lock.
    private func ensureCacheLocked() {
        if cacheLoaded, cachedFileBytes == currentFileBytes() { return }
        rebuildCacheLocked()
        cacheLoaded = true
    }

    /// Rebuild the in-memory set from the whole file. Caller holds the lock.
    private func rebuildCacheLocked() {
        cachedIds = []
        cachedFileBytes = currentFileBytes()
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        for (_, payload) in Self.records(in: data) {
            cachedIds.insert(payload)
        }
    }

    /// The current on-disk size in bytes (0 when the file is absent), via file
    /// attributes (no read) so the cache-freshness check is O(1). Caller holds
    /// the lock.
    private func currentFileBytes() -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int else {
            return 0
        }
        return size
    }

    /// Decode every length-framed record in `data` as (offset, payload) pairs in
    /// file (append) order. A truncated / malformed tail stops parsing; a record
    /// is always (4-byte BE length)(payload).
    private static func records(in data: Data) -> [(offset: Int, payload: Data)] {
        var out: [(offset: Int, payload: Data)] = []
        var offset = 0
        while offset + headerSize <= data.count {
            let length = Int(
                (UInt32(data[offset]) << 24) |
                (UInt32(data[offset + 1]) << 16) |
                (UInt32(data[offset + 2]) << 8) |
                UInt32(data[offset + 3])
            )
            offset += headerSize
            guard offset + length <= data.count else { break }
            out.append((offset, data[offset..<(offset + length)]))
            offset += length
        }
        return out
    }

    /// Bound the store (P1 #12): when the recorded set exceeds `maxCapacity`,
    /// rewrite the file keeping only the MOST RECENT `maxCapacity` ids (the
    /// newest appends) and drop the rest. Idempotent; only touches the file when
    /// over the cap. Caller holds the lock.
    private func pruneLocked() {
        guard cachedIds.count > maxCapacity,
              let data = try? Data(contentsOf: fileURL) else { return }
        let all = Self.records(in: data)
        guard all.count > maxCapacity else { return }
        // Newest ids are the LAST records (append order); keep them.
        let keep = Set(all.suffix(maxCapacity).map { $0.payload })
        var out = Data()
        for (_, payload) in all.suffix(maxCapacity) {
            let length = UInt32(payload.count)
            var header = Data(count: Self.headerSize)
            header[0] = UInt8((length >> 24) & 0xFF)
            header[1] = UInt8((length >> 16) & 0xFF)
            header[2] = UInt8((length >> 8) & 0xFF)
            header[3] = UInt8(length & 0xFF)
            out.append(header)
            out.append(payload)
        }
        do {
            try out.write(to: fileURL, options: .atomic)
        } catch {
            // A prune failure must not break the send path: the store stays
            // (slightly) over cap until the next record retries the prune.
            return
        }
        cachedIds = keep
        cachedFileBytes = out.count
    }

    /// Run `body` while holding an exclusive advisory lock on a sibling `.lock`
    /// file (identical strategy to `OutboxQueue` / `SharedFrameQueue`).
    private func withFileLock<T>(_ body: () -> T) -> T {
        let lockPath = fileURL.path + ".lock"
        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }
        let lockFd = Darwin.open(lockPath, O_RDWR)
        guard lockFd >= 0 else {
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
