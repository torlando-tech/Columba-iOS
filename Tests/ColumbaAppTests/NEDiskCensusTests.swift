import XCTest
@testable import ColumbaApp

final class NEDiskCensusTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ne-census-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    @discardableResult
    private func file(_ path: String, in root: URL, modifiedAt: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        return url
    }

    private func fixedAllocationMetadata(_ url: URL) throws -> NEDiskCensus.Metadata {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey])
        return .init(
            isDirectory: values.isDirectory == true, isRegularFile: values.isRegularFile == true,
            allocatedBytes: values.isRegularFile == true ? 4096 : nil,
            modifiedAt: values.contentModificationDate
        )
    }

    private func snapshot(
        _ buckets: [NEDiskCensus.Bucket], time: Int64 = 0,
        issues: Set<NEDiskCensus.IncompleteReason> = []
    ) -> NEDiskCensus.Snapshot {
        NEDiskCensus.Snapshot(
            uptimeMs: time, observedAt: epoch.addingTimeInterval(Double(time) / 1000),
            modifiedSince: time == 0 ? nil : epoch, buckets: buckets, issues: issues
        )
    }

    func testNormalizesRealRuntimeWrappersWithoutLosingRootOrStorageCategory() {
        let hash = String(repeating: "aB12", count: 8)
        for wrapper in ["python-current", "python-\(hash)"] {
            for directory in ["cache/announces", "storage/identities", "lxmf-storage/messages"] {
                XCTAssertEqual(
                    NEDiskCensus.bucketKey(forRelativePath: "ag/Columba/\(wrapper)/\(directory)/payload"),
                    "ag/\(directory)"
                )
            }
        }
        XCTAssertEqual(NEDiskCensus.bucketKey(forRelativePath: "ag/ne-memory.bin"), "ag")
        XCTAssertEqual(NEDiskCensus.bucketKey(forRelativePath: "tmp/cache/announces/file"), "tmp/cache/announces")
        XCTAssertEqual(NEDiskCensus.bucketKey(forRelativePath: "ag/cache/announces/deeper/file"), "ag/cache/announces")
    }

    func testClosedVocabularyMasksEmbeddedIdentifiersAndArbitraryPII() throws {
        let hash = "0123456789aBcDeF0123456789aBcDeF"
        let paths = [
            "ag/Columba/python-identity-\(hash)/cache/file",
            "ag/messages/prefix-\(hash)-suffix/file",
            "ag/alice@example.org/phone-5551234567/file",
            "ag/\nsecret-user/用户姓名/file",
            "user-\(hash)/cache/file"
        ]
        let keys = paths.map { NEDiskCensus.bucketKey(forRelativePath: $0) }
        XCTAssertEqual(keys, [
            "ag/«hash»/cache", "ag/messages/«hash»", "ag/«other»/«other»",
            "ag/«other»/«other»", "«other»/cache"
        ])
        let before = snapshot([])
        let after = snapshot(keys.map { .init(path: $0, files: 1, bytes: 4096) }, time: 900_000)
        let lines = NEDiskCensus.renderAbsolute(after) + NEDiskCensus.renderComparison(before: before, after: after)
        let identifier = try NSRegularExpression(pattern: "[0-9a-fA-F]{16,}")
        XCTAssertNil(identifier.firstMatch(in: lines, range: NSRange(lines.startIndex..., in: lines)))
        for secret in [hash, "alice", "5551234567", "secret-user", "用户姓名", "payload"] {
            XCTAssertFalse(lines.contains(secret))
        }
    }

    func testScanAggregatesActualLayoutsWithoutKeepingFileNames() throws {
        let root = try temporaryRoot()
        let hash = String(repeating: "a", count: 32)
        try file("Columba/python-current/cache/announces/first-private-file", in: root, modifiedAt: epoch)
        try file("Columba/python-\(hash)/cache/announces/second-private-file", in: root, modifiedAt: epoch)
        try file("Columba/python-current/storage/identities/private-file", in: root, modifiedAt: epoch)
        try file("Columba/python-current/lxmf-storage/messages/private-file", in: root, modifiedAt: epoch)
        let result = NEDiskCensus.snapshot(roots: [.init(label: "ag", url: root)], uptimeMs: 0)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(Set(result.buckets.map(\.path)), [
            "ag/cache/announces", "ag/storage/identities", "ag/lxmf-storage/messages"
        ])
        XCTAssertEqual(result.buckets.first { $0.path == "ag/cache/announces" }?.files, 2)
        XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.files }, 4)
        XCTAssertFalse(NEDiskCensus.renderAbsolute(result).contains("private-file"))
        XCTAssertFalse(NEDiskCensus.renderAbsolute(result).contains(root.path))
    }

    func testSymlinkRootUsesCanonicalLayoutAndRetainsItsLogicalLabel() throws {
        let root = try temporaryRoot()
        let links = try temporaryRoot()
        try file("cache/announces/private-file", in: root, modifiedAt: epoch)
        let alias = links.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        let result = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: alias)], uptimeMs: 0
        )

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.visitedEntries, 4)
        XCTAssertEqual(result.buckets.count, 1)
        XCTAssertEqual(result.buckets.first?.path, "ag/cache/announces")
        XCTAssertEqual(result.buckets.first?.files, 1)
        XCTAssertFalse(NEDiskCensus.renderAbsolute(result).contains(alias.path))
        XCTAssertFalse(NEDiskCensus.renderAbsolute(result).contains(root.path))
    }

    func testEntryCapCountsDirectoriesEvenWithNoFiles() throws {
        let root = try temporaryRoot()
        for index in 0..<20 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("directory-\(index)"), withIntermediateDirectories: true
            )
        }
        let result = NEDiskCensus.snapshot(roots: [.init(label: "ag", url: root)], uptimeMs: 0, cap: 4)
        XCTAssertEqual(result.visitedEntries, 4)
        XCTAssertTrue(result.buckets.isEmpty)
        XCTAssertEqual(result.issues, [.entryCap])
    }

    func testEntryCapIsSharedAcrossRootsAndCountsRootDirectories() throws {
        let first = try temporaryRoot()
        let second = try temporaryRoot()
        try file("one", in: first)
        try file("two", in: second)
        let roots = [NEDiskCensus.Root(label: "ag", url: first), .init(label: "tmp", url: second)]
        let capped = NEDiskCensus.snapshot(roots: roots, uptimeMs: 0, cap: 3)
        XCTAssertEqual(capped.visitedEntries, 3)
        XCTAssertEqual(capped.buckets.map(\.path), ["ag"])
        XCTAssertEqual(capped.issues, [.entryCap])
        let complete = NEDiskCensus.snapshot(roots: roots, uptimeMs: 0, cap: 4)
        XCTAssertEqual(complete.visitedEntries, 4)
        XCTAssertEqual(Set(complete.buckets.map(\.path)), ["ag", "tmp"])
        XCTAssertTrue(complete.isComplete)
    }

    func testCancellationInterruptsTraversalBeforeRemainingEntries() throws {
        let root = try temporaryRoot()
        for index in 0..<10 { try file("file-\(index)", in: root) }
        var reads = 0
        let result = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root)], uptimeMs: 0,
            isCancelled: { reads >= 2 },
            readMetadata: { url in
                reads += 1
                return .init(isDirectory: url == root, isRegularFile: url != root,
                             allocatedBytes: 4096, modifiedAt: self.epoch)
            }
        )
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(result.visitedEntries, 2)
        XCTAssertEqual(result.issues, [.cancelled])
    }

    func testMonotonicDeadlineInterruptsTraversalDeterministically() throws {
        let root = try temporaryRoot()
        for index in 0..<10 { try file("file-\(index)", in: root) }
        var clock: TimeInterval = 0
        let result = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root)], uptimeMs: 0, timeLimit: 1,
            monotonicNow: { clock },
            readMetadata: { url in
                if url != root { clock = 1 }
                return .init(isDirectory: url == root, isRegularFile: url != root,
                             allocatedBytes: 4096, modifiedAt: self.epoch)
            }
        )
        XCTAssertEqual(result.visitedEntries, 2)
        XCTAssertEqual(result.issues, [.timeLimit])
    }

    func testEnumerationFailureAfterRootDisappearsMarksSnapshotPartial() throws {
        let root = try temporaryRoot()
        let result = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root)], uptimeMs: 0,
            readMetadata: { url in
                XCTAssertEqual(url, root)
                try FileManager.default.removeItem(at: root)
                return .init(isDirectory: true, isRegularFile: false, allocatedBytes: nil, modifiedAt: nil)
            }
        )
        XCTAssertEqual(result.issues, [.enumerationError])
        XCTAssertFalse(result.isComplete)
    }

    func testMissingRootsAndResourceFailuresArePartial() throws {
        let root = try temporaryRoot()
        try file("unreadable", in: root)
        let missing = NEDiskCensus.snapshot(roots: [.init(label: "ag", url: nil)], uptimeMs: 0)
        XCTAssertEqual(missing.issues, [.missingRoot])
        let nonexistent = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root.appendingPathComponent("missing"))], uptimeMs: 0
        )
        XCTAssertTrue(nonexistent.issues.contains(.missingRoot))
        let unreadable = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root)], uptimeMs: 0,
            readMetadata: { url in
                if url != root { throw CocoaError(.fileReadNoPermission) }
                return .init(isDirectory: true, isRegularFile: false, allocatedBytes: nil, modifiedAt: nil)
            }
        )
        XCTAssertEqual(unreadable.issues, [.resourceError])
        XCTAssertTrue(unreadable.buckets.isEmpty)
        let unavailableSize = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root)], uptimeMs: 0,
            readMetadata: { url in
                .init(isDirectory: url == root, isRegularFile: url != root,
                      allocatedBytes: nil, modifiedAt: self.epoch)
            }
        )
        XCTAssertEqual(unavailableSize.issues, [.resourceError])
        let unavailableMtime = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root)], uptimeMs: 0,
            readMetadata: { url in
                .init(isDirectory: url == root, isRegularFile: url != root,
                      allocatedBytes: 4096, modifiedAt: nil)
            }
        )
        XCTAssertEqual(unavailableMtime.issues, [.resourceError])
        XCTAssertEqual(unavailableMtime.buckets.first?.files, 1)
    }

    func testAnyPartialEndpointSuppressesComparisonIncludingPartialBaseline() {
        let complete = snapshot([.init(path: "ag/cache", files: 1, bytes: 4096)])
        for reason in [NEDiskCensus.IncompleteReason.entryCap, .timeLimit, .cancelled,
                       .enumerationError, .resourceError, .missingRoot] {
            let partial = snapshot([], time: 900_000, issues: [reason])
            XCTAssertNil(NEDiskCensus.compare(before: complete, after: partial))
            XCTAssertNil(NEDiskCensus.compare(before: partial, after: complete))
            XCTAssertTrue(NEDiskCensus.renderComparison(before: partial, after: complete).contains("suppressed"))
        }
    }

    func testTotalsIncludeAllBucketsBeforeTopSixAndRankLossesAheadOfZeros() throws {
        let before = snapshot([
            .init(path: "ag/storage", files: 1, bytes: 50 * 1024),
            .init(path: "ag/Library", files: 1, bytes: 1024)
        ])
        let categories = ["cache", "messages", "identities", "ratchets", "resources", "packets", "lxmf-storage"]
        let after = snapshot([
            .init(path: "ag/Library", files: 1, bytes: 1024)
        ] + categories.map { .init(path: "ag/\($0)", files: 1, bytes: 10 * 1024) }, time: 900_000)
        let comparison = try XCTUnwrap(NEDiskCensus.compare(before: before, after: after))
        XCTAssertEqual(comparison.totalBytes, 20 * 1024)
        XCTAssertEqual(comparison.totalFiles, 6)
        XCTAssertEqual(comparison.changes.count, 8)
        XCTAssertEqual(comparison.changes.first?.path, "ag/storage")
        XCTAssertEqual(comparison.changes.first?.bytes, -50 * 1024)
        XCTAssertFalse(comparison.changes.contains { $0.path == "ag/Library" })
        let line = NEDiskCensus.renderComparison(before: before, after: after)
        XCTAssertTrue(line.contains("net allocated +20KiB +6f"))
        XCTAssertEqual(line.components(separatedBy: " mtime=").count - 1, 6)
        XCTAssertFalse(line.contains("KB/s"))
        XCTAssertFalse(line.contains("allowance"))
    }

    func testSameSizeOverwriteIsObservedByMtimeWithoutInventingBytesWritten() throws {
        let root = try temporaryRoot()
        let url = try file("Columba/python-current/cache/announces/file", in: root, modifiedAt: epoch.addingTimeInterval(-10))
        let roots = [NEDiskCensus.Root(label: "ag", url: root)]
        let before = NEDiskCensus.snapshot(
            roots: roots, uptimeMs: 0, observedAt: epoch, readMetadata: fixedAllocationMetadata
        )
        // Real same-size overwrite. The fixed metadata reader makes allocation
        // deterministic across filesystems while still reading the real mtime.
        try Data(repeating: 2, count: 4096).write(to: url)
        let changedAt = epoch.addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: changedAt], ofItemAtPath: url.path)
        let after = NEDiskCensus.snapshot(
            roots: roots, uptimeMs: 30_000, observedAt: epoch.addingTimeInterval(30), modifiedSince: before.observedAt,
            readMetadata: fixedAllocationMetadata
        )
        XCTAssertTrue(before.isComplete)
        XCTAssertTrue(after.isComplete)
        XCTAssertEqual(before.buckets.first?.bytes, after.buckets.first?.bytes)
        XCTAssertEqual(after.buckets.first?.modifiedFiles, 1)
        XCTAssertEqual(after.buckets.first?.latestModification, changedAt)
        let comparison = try XCTUnwrap(NEDiskCensus.compare(before: before, after: after))
        XCTAssertEqual(comparison.totalBytes, 0)
        XCTAssertEqual(comparison.modifiedFiles, 1)
        XCTAssertEqual(comparison.changes.count, 1)
        XCTAssertEqual(comparison.changes.first?.path, "ag/cache/announces")
        let line = NEDiskCensus.renderComparison(before: before, after: after)
        XCTAssertTrue(line.contains("net allocated +0KiB"))
        XCTAssertTrue(line.contains("observed-files=1"))
        XCTAssertTrue(line.contains("incomplete mtime observation"))
    }

    func testMtimeAggregationCountsOnlySurvivingFilesNewerThanPreviousSnapshot() throws {
        let root = try temporaryRoot()
        try file("cache/announces/old", in: root, modifiedAt: epoch.addingTimeInterval(-1))
        try file("cache/announces/equal", in: root, modifiedAt: epoch)
        try file("cache/announces/new", in: root, modifiedAt: epoch.addingTimeInterval(2))
        try file("cache/announces/newer", in: root, modifiedAt: epoch.addingTimeInterval(3))
        let result = NEDiskCensus.snapshot(
            roots: [.init(label: "ag", url: root)], uptimeMs: 10_000,
            observedAt: epoch.addingTimeInterval(10), modifiedSince: epoch
        )
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.buckets.count, 1)
        XCTAssertEqual(result.buckets.first?.files, 4)
        XCTAssertEqual(result.buckets.first?.modifiedFiles, 2)
        XCTAssertEqual(result.buckets.first?.latestModification, epoch.addingTimeInterval(3))
    }
}
