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

    /// Create the store in the App-Group container, falling back to a tmp file
    /// when the container is unavailable (unsigned builds / unit tests). The
    /// fallback is intentional so the dedup logic stays unit-testable on the
    /// simulator (the app group is not present there).
    public init(appGroupIdentifier: String = appGroupIdentifier, name: String = SentIdStore.defaultFileName) {
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
    init(tempFileURL: URL) {
        self.fileURL = tempFileURL
    }

    // MARK: API

    /// Record a sent id. Idempotent: a known id is a no-op. Concurrency-safe via
    /// the advisory file lock (the contains-check and append run under it).
    public func record(_ id: String) {
        let payload = Data(id.utf8)
        guard !payload.isEmpty else { return }
        let length = UInt32(payload.count)
        var header = Data(count: Self.headerSize)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        withFileLock {
            // Idempotency: skip if already recorded (keeps the file a set).
            if containsLocked(id, payload: payload) { return }
            let fh: FileHandle
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = h
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
                fh = h
            }
            fh.seekToEndOfFile()
            fh.write(header)
            fh.write(payload)
            fh.closeFile()
        }
    }

    /// True if the id has been recorded (already sent).
    public func contains(_ id: String) -> Bool {
        var found = false
        withFileLock {
            found = containsLocked(id, payload: Data(id.utf8))
        }
        return found
    }

    // MARK: Lock + scan

    /// Read every recorded id from the file and return true if `payload` matches
    /// one. Caller must hold the file lock (`withFileLock`).
    private func containsLocked(_ id: String, payload: Data) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return false
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
            guard offset + length <= data.count else { break }
            if data[offset..<(offset + length)] == payload {
                return true
            }
            offset += length
        }
        return false
    }

    /// Run `body` while holding an exclusive advisory lock on a sibling `.lock`
    /// file (identical strategy to `OutboxQueue` / `SharedFrameQueue`).
    private func withFileLock(_ body: () -> Void) {
        let lockPath = fileURL.path + ".lock"
        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }
        let lockFd = Darwin.open(lockPath, O_RDWR)
        guard lockFd >= 0 else {
            body()
            return
        }
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        fl.l_whence = Int16(SEEK_SET)
        fl.l_start = 0
        fl.l_len = 0
        _ = fcntl(lockFd, F_SETLKW, &fl)
        body()
        fl.l_type = Int16(F_UNLCK)
        _ = fcntl(lockFd, F_SETLK, &fl)
        Darwin.close(lockFd)
    }
}
