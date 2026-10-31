//
// NEDiskCensus.swift
// Columba Shared
//
// Attributes the Network Extension's disk writes to a DIRECTORY.
//
// -- WHY THIS EXISTS ---------------------------------------------------------
// The NE sustains roughly 100 KB/s of writes — measured from the memory ring's
// `ri_diskio_byteswritten` counter: one 9.4 h generation dirtied 3.9 GB, about
// 732x the per-day file-backed-write allowance iOS enforces on background
// processes. Sustaining that is the most likely way this process gets throttled
// or killed next, and the ring answers only HOW MUCH was written, never WHERE.
//
// Nothing outside this process can answer where either. The container lives
// inside the NE's own sandbox and a non-jailbroken device gives the host no AFC
// access to another process's files, so `devicectl` can pull a file we already
// know the path of but cannot enumerate the tree. The NE has to walk its own
// container and write the answer down.
//
// -- WHAT IT RECORDS ---------------------------------------------------------
// Per-directory file count + total allocated bytes, snapshotted on a 15-minute
// cadence, with the delta since the previous snapshot logged. Directory
// granularity is deliberate: it names the writer (RNS's announce cache, LXMF
// message storage, the SQLite WAL, Python's `__pycache__`) without copying the
// container's file list into a log that leaves the device.
//
// Allocated size, not logical size, is what gets compared. The OS write
// allowance is charged against file-backed memory, which is page-granular, so
// thousands of 150-byte files cost far more against the allowance than their
// byte sum suggests — and a census that reported logical bytes would hide
// exactly the churn pattern that matters.
//
// -- NO-PII CONTRACT (HARD RULE) ---------------------------------------------
// Lines carry bucket names and numbers ONLY. A bucket name is a container-
// RELATIVE directory path at bounded depth. File names never appear. Absolute
// paths never appear. Any component that looks like an identifier (16+ hex
// chars — a destination hash, a packet hash) is masked, because RNS stores
// message data under `messages/<dest_hash>/` and LXMF caches announces under
// their packet hash. See the `ExtensionDiagLog` header for the full contract.
//
// -- COST --------------------------------------------------------------------
// Read-only, one bounded tree walk per interval, on a background-QoS native
// thread (same reasoning as `NEMemoryTrace`: the NE's main dispatch thread is
// blocked during bring-up and announce floods). The census must never become
// the thing it is measuring.

import Foundation

public enum NEDiskCensus {

    // MARK: - Model

    /// One directory bucket: how many files it holds and their allocated size.
    public struct Bucket: Equatable, Sendable {
        /// Container-relative directory path, hash-like components masked.
        public let path: String
        public let files: Int
        public let bytes: Int64

        public init(path: String, files: Int, bytes: Int64) {
            self.path = path
            self.files = files
            self.bytes = bytes
        }
    }

    /// A whole-container snapshot.
    public struct Snapshot: Sendable {
        public let uptimeMs: Int64
        public let buckets: [Bucket]

        public init(uptimeMs: Int64, buckets: [Bucket]) {
            self.uptimeMs = uptimeMs
            self.buckets = buckets
        }
    }

    /// Change in one bucket between two snapshots. A bucket that vanished
    /// entirely reports its whole former contents as a loss — deleting a
    /// thousand files is churn too, and the sawtooth is the signal.
    public struct Growth: Equatable, Sendable {
        public let path: String
        public let files: Int
        public let bytes: Int64

        public init(path: String, files: Int, bytes: Int64) {
            self.path = path
            self.files = files
            self.bytes = bytes
        }
    }

    // MARK: - Tuning

    /// Path components that form a bucket key. Two is enough to separate
    /// `cache/announces` from `storage/identities` without approaching
    /// per-file granularity.
    static let bucketDepth = 2

    /// Files that look like identifiers get masked, not logged.
    static let hashComponentMinLength = 16

    /// Walk bound: a churning cache can hold tens of thousands of files, and a
    /// census that spins the CPU for minutes defeats its own purpose. Truncation
    /// is reported rather than hidden.
    static let maxEntries = 20_000

    /// Buckets per log line.
    static let topBuckets = 6

    /// Between snapshots. Matches RNS's `Reticulum.CLEAN_INTERVAL` (15 min) so
    /// the announce-cache churn shows up as a sawtooth instead of being
    /// averaged away across a longer window.
    public static let intervalSeconds: Double = 15 * 60

    // MARK: - Pure core (no filesystem, fully testable)

    /// Bucket key for a container-relative file path: the root label plus up to
    /// `bucketDepth` DIRECTORY components, identifier-like ones masked, file name
    /// dropped. The label is not part of the depth budget — it is what keeps the
    /// App-Group container and the temp dir from merging into one bucket, and
    /// counting it would collapse `ag/cache/announces` into `ag/cache` and throw
    /// away the attribution the whole census exists to provide. A file sitting at
    /// a container root buckets under the bare label.
    public static func bucketKey(forRelativePath path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return "/" }
        let label = String(components[0])
        let directories = components[1..<(components.count - 1)].prefix(bucketDepth).map { mask($0) }
        return ([label] + directories).joined(separator: "/")
    }

    /// `«hash»` for anything that reads as a raw identifier — 16+ hex chars is
    /// an RNS destination (16 bytes) or packet (16 bytes) hash. Everything else
    /// passes through: `announces`, `identities`, `Database` are the names we
    /// need to see.
    static func mask(_ component: some StringProtocol) -> String {
        let text = String(component)
        guard text.count >= hashComponentMinLength else { return text }
        return text.allSatisfy(\.isHexDigit) ? "«hash»" : text
    }

    /// Aggregate file entries into buckets, largest first (ties by name, so the
    /// ordering is stable and the log is diffable).
    public static func buckets(from entries: [(path: String, size: Int64)]) -> [Bucket] {
        var fileCount: [String: Int] = [:]
        var byteCount: [String: Int64] = [:]
        for entry in entries {
            let key = bucketKey(forRelativePath: entry.path)
            fileCount[key, default: 0] += 1
            byteCount[key, default: 0] += entry.size
        }
        return byteCount
            .map { Bucket(path: $0.key, files: fileCount[$0.key] ?? 0, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// Per-bucket change, largest gain first. Buckets present only in `before`
    /// are included as losses.
    public static func growth(before: Snapshot, after: Snapshot, limit: Int) -> [Growth] {
        let afterByKey = Dictionary(after.buckets.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var deltas: [Growth] = []
        deltas.reserveCapacity(after.buckets.count + before.buckets.count)

        for bucket in after.buckets {
            let previous = before.buckets.first { $0.path == bucket.path }
            deltas.append(Growth(
                path: bucket.path,
                files: bucket.files - (previous?.files ?? 0),
                bytes: bucket.bytes - (previous?.bytes ?? 0)
            ))
        }
        for previous in before.buckets where afterByKey[previous.path] == nil {
            deltas.append(Growth(path: previous.path, files: -previous.files, bytes: -previous.bytes))
        }
        return Array(deltas
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            .prefix(limit))
    }

    /// Boot line: the absolute layout, so the next pull has a starting point.
    public static func renderAbsolute(_ snapshot: Snapshot, truncated: Bool) -> String {
        let totalBytes = snapshot.buckets.reduce(Int64(0)) { $0 + $1.bytes }
        let totalFiles = snapshot.buckets.reduce(0) { $0 + $1.files }
        let top = snapshot.buckets.prefix(topBuckets)
            .map { "\($0.path)=\($0.files)f/\(kib($0.bytes))KB" }
            .joined(separator: " ")
        return "census boot: \(totalFiles)f/\(kib(totalBytes))KB in \(snapshot.buckets.count) dirs"
            + (truncated ? " (walk capped at \(maxEntries))" : "")
            + " [\(top)]"
    }

    /// Delta line: which directory grew, and the resulting rate. The rate is
    /// printed next to the total so the line can be compared directly against the
    /// 0.14 KB/s allowance the Memory screen charts — which is also why it carries
    /// two decimals: at one decimal a quiet window renders as `0.0 KB/s` and the
    /// comparison against the allowance silently disappears.
    public static func renderGrowth(_ deltas: [Growth], windowSeconds: Double) -> String {
        let totalBytes = deltas.reduce(Int64(0)) { $0 + $1.bytes }
        let rate = windowSeconds > 0 ? Double(totalBytes) / windowSeconds / 1024.0 : 0
        let top = deltas.map { delta -> String in
            let sign = delta.bytes < 0 ? "-" : "+"
            let fileSign = delta.files < 0 ? "-" : "+"
            return "\(delta.path)=\(fileSign)\(abs(delta.files))f/\(sign)\(kib(abs(delta.bytes)))KB"
            }
            .joined(separator: " ")
        let totalSign = totalBytes < 0 ? "-" : "+"
        return "census Δ\(Int(windowSeconds))s total \(totalSign)\(kib(abs(totalBytes)))KB "
            + "(\(String(format: "%.2f", rate)) KB/s) [\(top)]"
    }

    private static func kib(_ bytes: Int64) -> Int64 {
        (bytes + 512) / 1024
    }

    // MARK: - Filesystem

    /// Roots to walk, each with a short label so buckets from different
    /// containers cannot collide. `nil` roots (no App-Group entitlement, e.g. a
    /// test runner) are skipped rather than fatal.
    public static func defaultRoots() -> [(label: String, url: URL)] {
        var roots: [(String, URL)] = []
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            roots.append(("ag", container))
        }
        roots.append(("tmp", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)))
        return roots
    }

    /// Bounded, read-only walk. Returns container-relative paths prefixed with
    /// the root label, plus allocated size. `truncated` is true when the walk hit
    /// `cap`, so a capped census is never mistaken for a complete one. `cap` is a
    /// test seam; production always walks with `maxEntries`.
    public static func entries(
        root: URL, label: String, cap: Int = maxEntries
    ) -> (entries: [(path: String, size: Int64)], truncated: Bool) {
        let base = root.path
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }   // unreadable subdirectory: skip, keep walking
        ) else {
            return ([], false)
        }
        var collected: [(path: String, size: Int64)] = []
        for case let url as URL in walker {
            if collected.count >= cap { return (collected, true) }
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
            ), values.isRegularFile == true else { continue }
            // Allocated size is the page-granular number; logical size is the
            // fallback for filesystems that do not report it.
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            var relative = url.path
            if relative.hasPrefix(base) { relative.removeFirst(base.count) }
            while relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            collected.append((path: "\(label)/\(relative)", size: size))
        }
        return (collected, false)
    }

    /// One snapshot across every root.
    public static func snapshot(
        roots: [(label: String, url: URL)], uptimeMs: Int64, cap: Int = maxEntries
    ) -> (Snapshot, Bool) {
        var collected: [(path: String, size: Int64)] = []
        var truncated = false
        for root in roots {
            let walk = entries(root: root.url, label: root.label, cap: cap)
            collected.append(contentsOf: walk.entries)
            truncated = truncated || walk.truncated
        }
        return (Snapshot(uptimeMs: uptimeMs, buckets: buckets(from: collected)), truncated)
    }

    // MARK: - Census thread

    private static let lock = NSLock()
    private static var censusRunning = false
    /// Bumped on every `start()`. A thread only keeps running while its OWN
    /// generation is current — a tunnel reconnect inside one process would
    /// otherwise leave a second walker behind for the life of the process,
    /// doubling the very I/O this instrument exists to measure.
    private static var censusGeneration = 0

    /// Start the census. Idempotent within a process.
    public static func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !censusRunning else { return }
        censusRunning = true
        censusGeneration += 1
        let generation = censusGeneration

        let thread = Thread { runCensusLoop(generation: generation) }
        thread.name = "columba.disk-census"
        thread.qualityOfService = .background
        thread.stackSize = 64 * 1024
        thread.start()
    }

    /// Ask the census to stop; it exits within one second of its current sleep.
    public static func stop() {
        lock.lock()
        censusRunning = false
        lock.unlock()
    }

    private static func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return censusRunning && generation == censusGeneration
    }

    private static func runCensusLoop(generation: Int) {
        let roots = defaultRoots()
        guard !roots.isEmpty else { return }

        var (previous, truncated) = snapshot(roots: roots, uptimeMs: Clocks.now().uptimeMs)
        ExtensionDiagLog.log(renderAbsolute(previous, truncated: truncated))
        var lastUptimeMs = previous.uptimeMs

        while isCurrent(generation) {
            var slept: Double = 0
            while slept < intervalSeconds, isCurrent(generation) {
                Thread.sleep(forTimeInterval: 1.0)
                slept += 1.0
            }
            guard isCurrent(generation) else { break }

            let now = Clocks.now().uptimeMs
            let (current, capped) = snapshot(roots: roots, uptimeMs: now)
            // Uptime, not wall clock: the device sleeping must not be reported
            // as a 15-minute window that wrote nothing.
            let window = Double(now - lastUptimeMs) / 1000.0
            let deltas = growth(before: previous, after: current, limit: topBuckets)
            ExtensionDiagLog.log(renderGrowth(deltas, windowSeconds: window)
                + (capped ? " (walk capped at \(maxEntries))" : ""))
            previous = current
            lastUptimeMs = now
        }
    }
}
