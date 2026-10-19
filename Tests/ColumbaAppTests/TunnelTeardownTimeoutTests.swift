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

    func testBoundedPreferencesNeverCancelsTimedOutOperation() async throws {
        // The helper's safety contract: a timed-out operation stays parked,
        // never cancelled - cancelling would drop the suspended framework
        // continuation's only owner. Observe cancellation from INSIDE the
        // operation and let it outlive the timeout.
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let sawCancellation = Flag()
        let finished = Flag()
        _ = try? await TunnelManager.boundedPreferences(name: "test.park", seconds: 0.2) {
            for _ in 0..<40 {
                if Task.isCancelled { sawCancellation.set() }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            finished.set()
            return 0
        }
        // Give the parked operation past its natural end: it must have run
        // to completion on its own, without ever observing cancellation.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(sawCancellation.isSet, "a timed-out operation must never be cancelled")
        XCTAssertTrue(finished.isSet, "the parked operation must keep running to completion")
    }
}
