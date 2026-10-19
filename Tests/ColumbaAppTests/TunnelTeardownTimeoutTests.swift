import XCTest
@testable import ColumbaApp

/// Regression for the "Connecting to network… forever" hang after switching
/// hosting mode back to foreground: the startup path awaits
/// NE-preferences calls (`loadAllFromPreferences` / `saveToPreferences`)
/// whose completion handler is delivered over the neagent XPC and can be
/// lost while a VPN session is active. `TunnelManager` bounds those awaits
/// with `awaitCompleted`; a lost completion must park the *task*, never the
/// startup. These tests pin the mechanism the fix relies on.
final class TunnelTeardownTimeoutTests: XCTestCase {

    func testAwaitCompletedReturnsFalseForNeverCompletingOperation() async {
        // Mirrors a lost NE completion: an operation that will not finish
        // anywhere near the deadline. The waiter must return at the
        // deadline and leave the operation running (the real fix parks a
        // suspended framework task; cancelling it would drop the suspended
        // continuation's only owner).
        let never = Task {
            try await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
        }
        let started = Date()
        let completed = await TunnelManager.awaitCompleted(never, seconds: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(completed, "a never-completing operation must report timeout")
        XCTAssertLessThan(elapsed, 2.0, "waiter must return at the deadline, not block")
        XCTAssertFalse(never.isCancelled, "parked task must not be cancelled")
    }

    func testAwaitCompletedReturnsTrueForFastSuccess() async {
        let fast = Task { 42 }
        let completed = await TunnelManager.awaitCompleted(fast, seconds: 2)
        XCTAssertTrue(completed)
        let value = await fast.value
        XCTAssertEqual(value, 42)
    }

    func testAwaitCompletedTreatsThrownErrorAsCompleted() async {
        struct Boom: Error {}
        let failing = Task<Int, any Error> { throw Boom() }
        let completed = await TunnelManager.awaitCompleted(failing, seconds: 2)
        XCTAssertTrue(completed, "a thrown error is a completion; the caller surfaces it")
    }

    @available(iOS 17.0, macOS 14.0, *)
    @MainActor
    func testDisableWithoutLoadedConfigIsImmediateNoOp() async throws {
        // Fresh install / load-timeout path: with no config handle, disable()
        // must return instantly so foreground startup proceeds to the node.
        let tunnel = TunnelManager()
        try await tunnel.disable()
        XCTAssertFalse(tunnel.isEnabled)
    }

    func testBoundedPreferencesReturnsValueOnSuccess() async throws {
        let value = try await TunnelManager.boundedPreferences(name: "test.ok", seconds: 2) { 7 }
        XCTAssertEqual(value, 7)
    }

    func testBoundedPreferencesThrowsTimeoutErrorAtDeadline() async {
        let started = Date()
        do {
            _ = try await TunnelManager.boundedPreferences(name: "test.stall", seconds: 0.3) {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                return 0
            }
            XCTFail("a stalled preferences op must surface preferencesTimedOut")
        } catch let error as TunnelManager.TunnelManagerError {
            XCTAssertEqual(error, .preferencesTimedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "must fail at the deadline, not hang")
    }

    func testBoundedPreferencesPropagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await TunnelManager.boundedPreferences(name: "test.boom", seconds: 2) {
                throw Boom()
            }
            XCTFail("the operation's own error must propagate")
        } catch is Boom {
            // expected: a real failure is reported, not masked as a timeout
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
