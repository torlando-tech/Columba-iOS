// Read-only, bounded observations of the NE's directory layout and modification
// times. Allocated-size changes are not disk writes: overwrites, deletions and
// filesystem allocation behavior prevent using this census as throughput.
// Only fixed directory vocabulary is emitted; filenames and arbitrary paths
// never leave the scanner.

import Foundation

enum NEDiskCensus {
    struct Bucket: Equatable, Sendable {
        let path: String
        var files: Int = 0
        var bytes: Int64 = 0
        var latestModification: Date?
        var modifiedFiles: Int = 0
    }

    enum IncompleteReason: String, Hashable, Sendable {
        case entryCap = "entry-cap"
        case timeLimit = "time-limit"
        case cancelled
        case enumerationError = "enumeration-error"
        case resourceError = "resource-error"
        case missingRoot = "missing-root"
    }

    struct Snapshot: Sendable {
        let uptimeMs: Int64
        let observedAt: Date
        let modifiedSince: Date?
        let buckets: [Bucket]
        var issues: Set<IncompleteReason> = []
        var visitedEntries: Int = 0

        var isComplete: Bool { issues.isEmpty }
    }

    struct Change: Equatable, Sendable {
        let path: String
        let files: Int
        let bytes: Int64
        let modifiedFiles: Int
        let latestModification: Date?
    }

    struct Comparison: Sendable {
        /// All changes, not just the displayed top buckets.
        let changes: [Change]
        let totalFiles: Int
        let totalBytes: Int64
        let modifiedFiles: Int
    }

    struct Root {
        let label: String
        let url: URL?
    }

    struct Metadata {
        let isDirectory: Bool
        let isRegularFile: Bool
        let allocatedBytes: Int64?
        let modifiedAt: Date?
    }

    static let bucketDepth = 2
    static let maxEntries = 20_000
    static let maxScanSeconds: TimeInterval = 5
    static let topBuckets = 6
    static let intervalSeconds: TimeInterval = 15 * 60

    // A closed vocabulary also masks non-hex PII, Unicode, control characters,
    // and identifier strings with a harmless-looking prefix or suffix.
    private static let safeDirectories: Set<String> = [
        "Columba", "cache", "announces", "storage", "identities", "messages",
        "lxmf-storage", "lxmf", "LXMF", "ratchets", "resources", "packets",
        "__pycache__", "Library", "Caches", "Application Support", "Documents",
        "tmp", "logs", "inbox", "outbox", "propagation", "peers", "reticulum"
    ]

    private static func containsIdentifier(_ text: some StringProtocol) -> Bool {
        var run = 0
        for byte in text.utf8 {
            if (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) {
                run += 1
                if run >= 16 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    private static func isPythonWrapper(_ text: Substring) -> Bool {
        if text == "python-current" { return true }
        guard text.hasPrefix("python-") else { return false }
        let suffix = text.dropFirst("python-".count)
        return suffix.count >= 16 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    static func bucketKey(forRelativePath path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return "«other»" }
        let label = first == "ag" || first == "tmp" ? String(first) : "«other»"
        guard components.count > 1 else { return label }
        var directories = components.dropFirst().dropLast()
        // The app stores RNS under ag/Columba/python-current (or an identity
        // generation). These wrappers must not consume the attribution depth.
        if directories.first == "Columba" {
            directories = directories.dropFirst()
        }
        if let wrapper = directories.first, isPythonWrapper(wrapper) {
            directories = directories.dropFirst()
        }
        let safe = directories.prefix(bucketDepth).map { component -> String in
            if containsIdentifier(component) { return "«hash»" }
            let text = String(component)
            return safeDirectories.contains(text) ? text : "«other»"
        }
        return ([label] + safe).joined(separator: "/")
    }

    static func compare(before: Snapshot, after: Snapshot) -> Comparison? {
        guard before.isComplete, after.isComplete else { return nil }
        let old = Dictionary(before.buckets.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.buckets.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [Change] = []
        var totalFiles = 0
        var totalBytes: Int64 = 0
        var modifiedFiles = 0
        for key in Set(old.keys).union(new.keys) {
            let files = (new[key]?.files ?? 0) - (old[key]?.files ?? 0)
            let bytes = (new[key]?.bytes ?? 0) - (old[key]?.bytes ?? 0)
            let modified = after.modifiedSince == before.observedAt ? (new[key]?.modifiedFiles ?? 0) : 0
            totalFiles += files
            totalBytes += bytes
            modifiedFiles += modified
            guard files != 0 || bytes != 0 || modified != 0 else { continue }
            changes.append(Change(
                path: key, files: files, bytes: bytes, modifiedFiles: modified,
                latestModification: new[key]?.latestModification
            ))
        }
        changes.sort {
            if $0.bytes.magnitude != $1.bytes.magnitude { return $0.bytes.magnitude > $1.bytes.magnitude }
            if $0.modifiedFiles != $1.modifiedFiles { return $0.modifiedFiles > $1.modifiedFiles }
            if $0.files.magnitude != $1.files.magnitude { return $0.files.magnitude > $1.files.magnitude }
            return $0.path < $1.path
        }
        return Comparison(changes: changes, totalFiles: totalFiles, totalBytes: totalBytes, modifiedFiles: modifiedFiles)
    }

    private static func kib(_ bytes: Int64) -> Int64 { bytes / 1024 }
    private static func signed(_ value: Int64) -> String { value >= 0 ? "+\(value)" : "\(value)" }
    private static func mtime(_ date: Date?) -> String {
        date.map { String(Int64($0.timeIntervalSince1970)) } ?? "unknown"
    }

    static func renderAbsolute(_ snapshot: Snapshot) -> String {
        let totalBytes = snapshot.buckets.reduce(Int64(0)) { $0 + $1.bytes }
        let totalFiles = snapshot.buckets.reduce(0) { $0 + $1.files }
        let top = snapshot.buckets.prefix(topBuckets).map {
            "\($0.path)=\($0.files)f/\(kib($0.bytes))KiB mtime=\(mtime($0.latestModification))"
        }.joined(separator: " ")
        let status = snapshot.isComplete ? "complete" : "partial:" + snapshot.issues.map(\.rawValue).sorted().joined(separator: ",")
        return "census layout \(status) visited=\(snapshot.visitedEntries) \(totalFiles)f/\(kib(totalBytes))KiB allocated [\(top)]"
    }

    static func renderComparison(before: Snapshot, after: Snapshot) -> String {
        guard let comparison = compare(before: before, after: after) else {
            return "census comparison suppressed (partial snapshot); " + renderAbsolute(after)
        }
        let top = comparison.changes.prefix(topBuckets).map {
            "\($0.path)=\(signed(Int64($0.files)))f/\(signed(kib($0.bytes)))KiB modified=\($0.modifiedFiles) mtime=\(mtime($0.latestModification))"
        }.joined(separator: " ")
        let observation = after.modifiedSince == before.observedAt
            ? "modified-since=\(mtime(after.modifiedSince)) observed-files=\(comparison.modifiedFiles)"
            : "modification-window=unavailable"
        return "census Δ\(max(0, after.uptimeMs - before.uptimeMs) / 1000)s net allocated \(signed(kib(comparison.totalBytes)))KiB \(signed(Int64(comparison.totalFiles)))f; "
            + "\(observation) (incomplete mtime observation, not bytes written or throughput) [\(top)]"
    }

    static func defaultRoots() -> [Root] {
        [
            Root(label: "ag", url: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)),
            Root(label: "tmp", url: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        ]
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .contentModificationDateKey
    ]

    private static func metadata(at url: URL) throws -> Metadata {
        let values = try url.resourceValues(forKeys: resourceKeys)
        return Metadata(
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true,
            allocatedBytes: (values.totalFileAllocatedSize ?? values.fileAllocatedSize).map { Int64($0) },
            modifiedAt: values.contentModificationDate
        )
    }

    /// Streaming aggregation retains only bounded, sanitized bucket names.
    /// The deadline and cancellation are cooperative between filesystem calls.
    static func snapshot(
        roots: [Root], uptimeMs: Int64, observedAt: Date = Date(), modifiedSince: Date? = nil,
        cap: Int = maxEntries, timeLimit: TimeInterval = maxScanSeconds,
        isCancelled: @escaping () -> Bool = { false },
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        readMetadata: (URL) throws -> Metadata = metadata
    ) -> Snapshot {
        let deadline = monotonicNow() + max(0, timeLimit)
        var issues: Set<IncompleteReason> = []
        var visited = 0
        var buckets: [String: Bucket] = [:]

        func interrupted() -> Bool {
            if isCancelled() { issues.insert(.cancelled); return true }
            if monotonicNow() >= deadline { issues.insert(.timeLimit); return true }
            return false
        }
        func admitEntry() -> Bool {
            guard !interrupted() else { return false }
            guard visited < max(0, cap) else { issues.insert(.entryCap); return false }
            visited += 1
            return true
        }

        if roots.isEmpty { issues.insert(.missingRoot) }
        rootLoop: for root in roots {
            guard !interrupted() else { break }
            guard let requestedURL = root.url else { issues.insert(.missingRoot); continue }
            // Foundation can enumerate a canonical /private/var URL even when
            // the requested root uses /var (or another symlink alias).
            let url = requestedURL.resolvingSymlinksInPath().standardizedFileURL
            // Root directories count against the same budget as descendants.
            guard admitEntry() else { break }
            do {
                guard try readMetadata(url).isDirectory else { issues.insert(.missingRoot); continue }
            } catch {
                issues.insert(.missingRoot)
                issues.insert(.resourceError)
                continue
            }
            guard !interrupted() else { break }
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(resourceKeys), options: [],
                errorHandler: { _, _ in issues.insert(.enumerationError); return !interrupted() }
            ) else {
                issues.insert(.enumerationError)
                continue
            }
            let base = url.path.hasSuffix("/") ? url.path : url.path + "/"
            while !interrupted() {
                guard let entry = walker.nextObject() as? URL else { break }
                guard admitEntry() else { break rootLoop }
                do {
                    let values = try readMetadata(entry)
                    guard !interrupted() else { break rootLoop }
                    guard values.isRegularFile else { continue }
                    guard let bytes = values.allocatedBytes, bytes >= 0 else {
                        issues.insert(.resourceError)
                        continue
                    }
                    if values.modifiedAt == nil { issues.insert(.resourceError) }
                    let entryPath = entry.resolvingSymlinksInPath().standardizedFileURL.path
                    guard entryPath.hasPrefix(base) else { issues.insert(.resourceError); continue }
                    let relative = entryPath.dropFirst(base.count)
                    let key = bucketKey(forRelativePath: "\(root.label)/\(relative)")
                    var bucket = buckets[key] ?? Bucket(path: key)
                    bucket.files += 1
                    bucket.bytes += bytes
                    if let modified = values.modifiedAt {
                        if bucket.latestModification == nil || modified > bucket.latestModification! {
                            bucket.latestModification = modified
                        }
                        if let since = modifiedSince, modified > since { bucket.modifiedFiles += 1 }
                    }
                    buckets[key] = bucket
                } catch {
                    issues.insert(.resourceError)
                }
            }
        }
        return Snapshot(
            uptimeMs: uptimeMs, observedAt: observedAt, modifiedSince: modifiedSince,
            buckets: buckets.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path },
            issues: issues, visitedEntries: visited
        )
    }

    private static let lock = NSLock()
    private static var censusRunning = false
    private static var censusGeneration = 0

    static func start() {
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

    static func stop() {
        lock.lock()
        censusRunning = false
        censusGeneration += 1
        lock.unlock()
    }

    private static func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return censusRunning && generation == censusGeneration
    }

    private static func logIfCurrent(_ line: String, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        // Serializing publication with stop prevents a completed old scan from
        // logging after stop or into a later start's generation.
        guard censusRunning && generation == censusGeneration else { return }
        ExtensionDiagLog.log(line)
    }

    private static func scan(roots: [Root], since: Date?, generation: Int) -> Snapshot {
        #if canImport(Darwin)
        return autoreleasepool {
            snapshot(roots: roots, uptimeMs: Clocks.now().uptimeMs, modifiedSince: since,
                     isCancelled: { !isCurrent(generation) })
        }
        #else
        return snapshot(roots: roots, uptimeMs: Clocks.now().uptimeMs, modifiedSince: since,
                        isCancelled: { !isCurrent(generation) })
        #endif
    }

    private static func runCensusLoop(generation: Int) {
        guard isCurrent(generation) else { return }
        let roots = defaultRoots()
        var previous = scan(roots: roots, since: nil, generation: generation)
        logIfCurrent(renderAbsolute(previous), generation: generation)
        while isCurrent(generation) {
            var slept: TimeInterval = 0
            while slept < intervalSeconds, isCurrent(generation) {
                Thread.sleep(forTimeInterval: 1)
                slept += 1
            }
            guard isCurrent(generation) else { return }
            let current = scan(roots: roots, since: previous.observedAt, generation: generation)
            logIfCurrent(renderComparison(before: previous, after: current), generation: generation)
            previous = current
        }
    }
}
