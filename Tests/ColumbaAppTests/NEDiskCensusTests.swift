import XCTest
@testable import ColumbaApp

/// Coverage for the NE's disk-write attribution census.
///
/// The census exists to answer exactly one question — WHICH directory is
/// writing — from inside a sandbox nothing outside it can inspect. Two failures
/// would make it worse than having nothing:
///
/// 1. A rendered line that leaks an identifier. RNS stores message data under
///    `messages/<dest_hash>/` and caches announces by packet hash, and this log
///    is copied off the device. Masking is a hard contract, not cosmetics.
/// 2. A rate wrong by 1024x. The line is read against the 0.14 KB/s allowance on
///    the Memory screen; a unit slip either hides a 732x overage or invents one.
final class NEDiskCensusTests: XCTestCase {

    // MARK: - Bucketing

    func testBucketKeyKeepsTheDirectoryAndDropsTheFile() {
        XCTAssertEqual(
            NEDiskCensus.bucketKey(forRelativePath: "ag/cache/announces/1a2b3c4d5e6f7890.dat"),
            "ag/cache/announces"
        )
    }

    func testBucketKeyDoesNotSpendTheRootLabelOnDepth() {
        // The label keeps the App-Group container and the temp dir from merging
        // into one bucket. Counting it toward `bucketDepth` would collapse every
        // App-Group path to `ag/<one dir>` and destroy the attribution.
        XCTAssertEqual(
            NEDiskCensus.bucketKey(forRelativePath: "ag/messages/deadbeefdeadbeef/body.dat"),
            "ag/messages/«hash»"
        )
        XCTAssertEqual(NEDiskCensus.bucketKey(forRelativePath: "ag/ne-memory.bin"), "ag")
        XCTAssertEqual(NEDiskCensus.bucketKey(forRelativePath: "orphan"), "/")
    }

    func testLongNonHexDirectoryNamesSurvive() {
        XCTAssertEqual(
            NEDiskCensus.bucketKey(forRelativePath: "ag/reticulum_storage_directory/x.dat"),
            "ag/reticulum_storage_directory"
        )
    }

    func testDistinctDestinationsCollapseIntoOneBucket() {
        // Per-peer buckets would bury the answer under thousands of equal lines.
        // The census reports the directory, not the destination.
        let buckets = NEDiskCensus.buckets(from: [
            (path: "ag/messages/\(String(repeating: "a", count: 32))/body.dat", size: 4096),
            (path: "ag/messages/\(String(repeating: "b", count: 32))/body.dat", size: 4096),
        ])
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.path, "ag/messages/«hash»")
        XCTAssertEqual(buckets.first?.files, 2)
        XCTAssertEqual(buckets.first?.bytes, 8192)
    }

    func testBucketsSortByBytesThenName() {
        let buckets = NEDiskCensus.buckets(from: [
            (path: "ag/small/a", size: 1024),
            (path: "ag/big/a", size: 400_000),
            (path: "ag/big/b", size: 1),
        ])
        XCTAssertEqual(buckets.map(\.path), ["ag/big", "ag/small"])
        XCTAssertEqual(buckets.first?.files, 2)
    }

    // MARK: - Growth

    func testGrowthReportsGainsAndVanishedDirectories() {
        let before = NEDiskCensus.Snapshot(uptimeMs: 0, buckets: [
            .init(path: "ag/cache/announces", files: 100, bytes: 100 * 4096),
            .init(path: "ag/gone", files: 5, bytes: 5 * 4096),
        ])
        let after = NEDiskCensus.Snapshot(uptimeMs: 900_000, buckets: [
            .init(path: "ag/cache/announces", files: 140, bytes: 140 * 4096),
        ])

        let deltas = NEDiskCensus.growth(before: before, after: after, limit: 5)
        XCTAssertEqual(deltas.first?.path, "ag/cache/announces")
        XCTAssertEqual(deltas.first?.files, 40)
        XCTAssertEqual(deltas.first?.bytes, 40 * 4096)

        // A directory that disappeared entirely still wrote. Deleting a thousand
        // files is churn, and reporting it as zero would hide the sawtooth the
        // announce cache produces when RNS cleans up.
        let vanished = deltas.first { $0.path == "ag/gone" }
        XCTAssertEqual(vanished?.files, -5)
        XCTAssertEqual(vanished?.bytes, -5 * 4096)
    }

    func testGrowthLimitKeepsTheLargestWriters() {
        let after = NEDiskCensus.Snapshot(uptimeMs: 0, buckets: (0..<10).map { index in
            NEDiskCensus.Bucket(path: "ag/d\(index)", files: 1, bytes: Int64(index) * 1024)
        })
        let deltas = NEDiskCensus.growth(
            before: NEDiskCensus.Snapshot(uptimeMs: 0, buckets: []), after: after, limit: 3
        )
        XCTAssertEqual(deltas.map(\.path), ["ag/d9", "ag/d8", "ag/d7"])
    }

    // MARK: - Rendering

    func testRenderedRateIsKilobytesPerSecond() {
        // 300 KiB over 900 s = 0.33 KB/s.
        let deltas = [NEDiskCensus.Growth(path: "ag/cache/announces", files: 10, bytes: 300 * 1024)]
        let line = NEDiskCensus.renderGrowth(deltas, windowSeconds: 900)
        XCTAssertTrue(line.contains("0.33 KB/s"), line)
        XCTAssertTrue(line.contains("total +300KB"), line)
        XCTAssertTrue(line.contains("ag/cache/announces=+10f/+300KB"), line)
    }

    func testQuietWindowStillShowsItsRateAgainstTheAllowance() {
        // 6 KiB over 900 s is 0.0067 KB/s. One decimal renders that as `0.0`,
        // which reads identically to a window that wrote nothing — and the whole
        // point of the number is the comparison against the 0.14 KB/s allowance.
        let line = NEDiskCensus.renderGrowth(
            [.init(path: "ag/Library", files: 1, bytes: 6 * 1024)], windowSeconds: 900
        )
        XCTAssertTrue(line.contains("0.01 KB/s"), line)
    }

    /// Hard contract: this log is copied out of the container and read off the
    /// device. RNS stores message data under `messages/<dest_hash>/` and caches
    /// announces under their packet hash, so an unmasked path would ship peer
    /// identifiers with the diagnostic.
    func testRenderedLinesCarryNoIdentifiersOrAbsolutePaths() throws {
        let hash = "0f1e2d3c4b5a69780f1e2d3c4b5a6978"
        let snapshot = NEDiskCensus.Snapshot(uptimeMs: 0, buckets: NEDiskCensus.buckets(from: [
            (path: "ag/messages/\(hash)/body.dat", size: 4096),
            (path: "tmp/Library/Caches/x.dat", size: 2048),
        ]))
        let empty = NEDiskCensus.Snapshot(uptimeMs: 0, buckets: [])
        let lines = [
            NEDiskCensus.renderAbsolute(snapshot, truncated: false),
            NEDiskCensus.renderGrowth(
                NEDiskCensus.growth(before: empty, after: snapshot, limit: 6), windowSeconds: 900
            ),
        ]
        let identifierRun = try NSRegularExpression(pattern: "[0-9a-fA-F]{16,}")
        for line in lines {
            XCTAssertFalse(line.contains("/Users"), line)
            XCTAssertFalse(line.contains("/var/"), line)
            XCTAssertNil(
                identifierRun.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                "rendered line leaks an identifier-length hex run: \(line)"
            )
        }
    }

    // MARK: - Walk

    func testWalkLabelsEntriesBucketsByDirectoryAndHonoursTheCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ne-census-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let announces = root.appendingPathComponent("cache/announces", isDirectory: true)
        try FileManager.default.createDirectory(at: announces, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("storage", isDirectory: true),
            withIntermediateDirectories: true
        )
        for name in ["a", "b", "c"] {
            try Data(count: 2048).write(to: announces.appendingPathComponent(name))
        }
        try Data(count: 1024).write(to: root.appendingPathComponent("storage/known_destinations"))

        let walk = NEDiskCensus.entries(root: root, label: "ag")
        XCTAssertEqual(walk.entries.count, 4)
        XCTAssertFalse(walk.truncated)
        XCTAssertTrue(walk.entries.allSatisfy { $0.path.hasPrefix("ag/") })
        XCTAssertFalse(walk.entries.contains { $0.path.contains(root.path) }, "absolute path leaked")

        let buckets = NEDiskCensus.buckets(from: walk.entries)
        XCTAssertEqual(buckets.first?.path, "ag/cache/announces")
        XCTAssertEqual(buckets.first?.files, 3)

        let capped = NEDiskCensus.entries(root: root, label: "ag", cap: 2)
        XCTAssertEqual(capped.entries.count, 2)
        XCTAssertTrue(capped.truncated)
    }
}
