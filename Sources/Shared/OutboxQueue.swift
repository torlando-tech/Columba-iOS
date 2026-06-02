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
//    • DRAIN (NE side, `NEReticulumNode.start`): once the in-NE node is fully up
//      (transport + router + delivery destination), it `drainAll()`s the queue and
//      replays each entry through its existing `sendLxmfForIPC(...)` path. The send
//      is then packed + signed + queued by LXMF-swift exactly as a live IPC send
//      would have been.
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
//  only) and the drain site (`NEReticulumNode`, imports ReticulumSwift + LXMFSwift)
//  both keep their own import sets; this Foundation-only seam is what lets them
//  share the queue without either gaining the other's imports.
//

import Foundation

// MARK: - OutboxEntry

/// One pending outbound LXMF send, persisted while the NE is down so it can be
/// replayed on the next NE start. The fields mirror `ProxyRequest.lxmfSend`
/// (`destHashHex` / `content` / `method` / `fieldsData`) so the drain site can
/// hand them straight to `NEReticulumNode.sendLxmfForIPC(...)` with no remapping.
///
/// `Codable` via Foundation's synthesized conformance; `Data` rides as base64 and
/// every other field is a JSON-native scalar, keeping the record (and this whole
/// file) Foundation-only.
public struct OutboxEntry: Codable, Sendable, Equatable {

    /// Lowercase-hex `lxmf.delivery` destination hash (mirrors
    /// `ProxyRequest.lxmfSend.destHashHex`).
    public let destHashHex: String

    /// Plaintext message body. Stored as `String` to match
    /// `ProxyRequest.lxmfSend.content` (the NE wraps it as `Data(content.utf8)`);
    /// JSON encodes it directly, no base64.
    public let content: String

    /// `RNSAPI.LXDeliveryMethod` raw value ("opportunistic" / "direct" /
    /// "propagated" / …), exactly as `ProxyRequest.lxmfSend.method` carries it. The
    /// NE maps it back via its `deliveryMethod(_:)` helper.
    public let method: String

    /// MessagePack-packed canonical LXMF field map (image / attachments / icon /
    /// reply / extras), pre-assembled APP-SIDE by `LxmfFieldCodec` — identical to
    /// `ProxyRequest.lxmfSend.fieldsData`. `nil` (or empty) means no fields. Stored
    /// optional here (rather than the wire type's non-optional empty-`Data`) so a
    /// no-fields entry serializes compactly; the drain site treats nil as empty.
    public let fieldsData: Data?

    /// App-computed message hash hex for dedup / reconciliation, when one is
    /// available — otherwise `nil`.
    ///
    /// In the Model B proxy path this is **always nil today**, and that is correct,
    /// not a TODO stub. The canonical LXMF message hash is
    /// `SHA256(destHash + sourceHash + msgpack([timestamp, title, content, fields]))`
    /// (see LXMF-swift `LXMessage.pack`), where `timestamp` is assigned at PACK
    /// time. Packing happens NE-side at drain (`sendLxmfForIPC` → `LXMRouter
    /// .handleOutbound`), and the proxy that enqueues here imports RNSAPI ONLY — it
    /// has no `Identity`, no LXMF-swift, and no pack-time timestamp, so it cannot
    /// compute the real hash. (The app's only "optimistic" id is a random `UUID` in
    /// `MessagingViewModel`, which is never passed down to the backend.) Dedup does
    /// NOT depend on this field: re-send safety is the receiver's responsibility
    /// (LXMF-swift caches seen inbound message hashes for ~1h and rejects
    /// duplicates), and the enqueue condition is gated to cases where the NE did NOT
    /// accept the send. The field is retained — optional — so a future track that
    /// threads the app's local id down to the proxy can populate it without a
    /// schema migration.
    public let messageHashHex: String?

    /// Wall-clock enqueue time (`Date().timeIntervalSince1970`), for diagnostics /
    /// future staleness pruning. NOT the LXMF pack timestamp (that's assigned
    /// NE-side at drain).
    public let createdAt: Double

    public init(
        destHashHex: String,
        content: String,
        method: String,
        fieldsData: Data?,
        messageHashHex: String?,
        createdAt: Double
    ) {
        self.destHashHex = destHashHex
        self.content = content
        self.method = method
        self.fieldsData = fieldsData
        self.messageHashHex = messageHashHex
        self.createdAt = createdAt
    }
}

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
        var entries: [OutboxEntry] = []

        withFileLock {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  !data.isEmpty else {
                return
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
                    // Truncated trailing record — stop parsing.
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

            // Truncate the file (read-all-and-clear).
            try? Data().write(to: fileURL, options: .atomic)
        }

        return entries
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
    private func withFileLock(_ body: () -> Void) {
        let lockPath = fileURL.path + ".lock"

        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }

        let lockFd = Darwin.open(lockPath, O_RDWR)
        guard lockFd >= 0 else {
            // Can't open the lock file — run without the lock (best effort), same
            // as `SharedFrameQueue`.
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
