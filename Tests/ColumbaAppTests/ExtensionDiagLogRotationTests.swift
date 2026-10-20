import XCTest
@testable import ColumbaApp

/// Regression for the unbounded NE diagnostics log: `ext-diag.log` grew to
/// 427 MB on a device in ~2.5 days because the NE runs for days and nothing
/// capped the file. `ExtensionDiagLog.log` now rotates the current generation
/// to `ext-diag.log.1` past the cap (mirroring the app-side `DiagLog`), and
/// `clear()` wipes both generations.
final class ExtensionDiagLogRotationTests: XCTestCase {

    private var fileURL: URL!
    private var rotatedURL: URL { URL(fileURLWithPath: fileURL.path + ".1") }

    override func setUpWithError() throws {
        fileURL = try XCTUnwrap(ExtensionDiagLog.fileURL, "App-Group container must exist in the hosted test runner")
        ExtensionDiagLog.clear()
    }

    override func tearDown() {
        ExtensionDiagLog.maxLogFileBytesOverride = nil
        ExtensionDiagLog.clear()
        super.tearDown()
    }

    private func currentSize() throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
    }

    func testAppendPastCapRotatesAndBoundsCurrentFile() throws {
        ExtensionDiagLog.maxLogFileBytesOverride = 2048
        let line = String(repeating: "x", count: 200)
        for _ in 0..<40 { ExtensionDiagLog.log(line) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path) == false,
                       "crossing the cap must produce the rotated generation")
        XCTAssertLessThanOrEqual(try currentSize(), 2048 + 512,
                                 "current generation stays bounded by cap + one line")

        let rotated = try XCTUnwrap(String(contentsOf: rotatedURL, encoding: .utf8))
        XCTAssertTrue(rotated.contains("x"), "rotated generation holds the pre-rotation lines")
    }

    func testClearRemovesBothGenerations() throws {
        ExtensionDiagLog.maxLogFileBytesOverride = 1024
        let line = String(repeating: "y", count: 200)
        for _ in 0..<20 { ExtensionDiagLog.log(line) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))

        ExtensionDiagLog.clear()

        XCTAssertEqual(try currentSize(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path),
                       "clear() must not leave a stale rotated generation behind")
    }

    func testBelowCapDoesNotRotate() throws {
        ExtensionDiagLog.maxLogFileBytesOverride = 100_000
        ExtensionDiagLog.log("single short line")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertTrue(ExtensionDiagLog.recentText().contains("single short line"))
    }
}
