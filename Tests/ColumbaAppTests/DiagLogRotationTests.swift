import XCTest
@testable import ColumbaApp

/// Contract tests for DiagLog launch-purge + size-capped rotation
/// (pre-public-beta privacy hygiene: pre-#186 builds leaked received
/// message plaintext into Documents/diag.log; the launch purge wipes it,
/// and the cap stops unbounded growth).
final class DiagLogRotationTests: XCTestCase {

    private var diagURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("diag.log")
    }
    private var rotatedURL: URL {
        URL(fileURLWithPath: diagURL.path + ".1")
    }

    override func setUp() {
        super.setUp()
        DiagLog.maxLogFileBytesOverride = nil
        try? FileManager.default.removeItem(at: diagURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    override func tearDown() {
        DiagLog.maxLogFileBytesOverride = nil
        try? FileManager.default.removeItem(at: diagURL)
        try? FileManager.default.removeItem(at: rotatedURL)
        super.tearDown()
    }

    // MARK: - Launch purge

    func testPurgeRemovesDiagLogAndRotatedFile() throws {
        // Seed a "pre-fix build" log containing fake leaked content plus a
        // rotated sibling, then purge: both must be gone.
        try "old leaked plaintext SECRET".data(using: .utf8)!.write(to: diagURL)
        try "old rotated plaintext SECRET".data(using: .utf8)!.write(to: rotatedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagURL.path))

        DiagLog.purgeForNewLaunch()

        XCTAssertFalse(FileManager.default.fileExists(atPath: diagURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path))
    }

    func testPurgeOnMissingFilesIsSafe() {
        // No files at all: purge must not throw or create anything.
        DiagLog.purgeForNewLaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagURL.path))
    }

    // MARK: - Size-capped rotation

    func testRotationTriggersAtCap() throws {
        DiagLog.maxLogFileBytesOverride = 200
        // Each line is ~40 bytes; 10 lines exceed 200 and must rotate.
        for i in 1...10 {
            DiagLog.log("rotation probe line \(i) padding padding padding")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotatedURL.path),
            "exceeding the cap must rotate diag.log to diag.log.1")
        // After rotation the live file is recreated only on the next append;
        // log one more line and confirm the live file is small again.
        DiagLog.log("post-rotation line")
        let liveSize = (try? Data(contentsOf: diagURL).count) ?? -1
        XCTAssertLessThanOrEqual(liveSize, 200, "live log must restart under the cap")
    }

    func testRotationReplacesPreviousRotatedFile() throws {
        DiagLog.maxLogFileBytesOverride = 100
        // Force two rotations; only ONE .1 file may exist (the latest).
        for i in 1...20 {
            DiagLog.log("cycle line \(i) padding padding padding padding")
        }
        // The final append may itself have rotated the live file away; append
        // one more so the live file definitely exists for inspection.
        DiagLog.log("final tail line")
        let rotated = try Data(contentsOf: rotatedURL)
        XCTAssertFalse(rotated.isEmpty)
        // The live file must not contain the oldest lines that were rotated out.
        let live = try String(contentsOf: diagURL, encoding: .utf8)
        XCTAssertFalse(live.contains("cycle line 1 "),
                       "oldest rotated lines must not remain in the live file")
    }

    func testBelowCapNoRotation() throws {
        DiagLog.maxLogFileBytesOverride = 10_000
        DiagLog.log("small line")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path),
                       "staying under the cap must not rotate")
    }

    // MARK: - Concurrency

    func testConcurrentAppendsAreSerialized() throws {
        DiagLog.maxLogFileBytesOverride = 10_000
        let iterations = 200
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            DiagLog.log("concurrent line \(i)")
        }
        let text = try String(contentsOf: diagURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, iterations,
                       "every concurrent append must land exactly once")
    }
}
