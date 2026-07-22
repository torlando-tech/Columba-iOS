import XCTest
#if COLUMBA_RUNTIME_MODEL_B
@testable import ColumbaModelBApp
#else
@testable import ColumbaApp
#endif

final class RuntimeActivityMonitorLeaseTests: XCTestCase {
    func testMonitorRunsUntilLastLeaseIsReleased() {
        let monitor = RuntimeActivityMonitor()

        let first = monitor.acquire()
        let second = monitor.acquire()
        XCTAssertTrue(monitor.isRunningForTesting)
        XCTAssertEqual(monitor.activeLeaseCountForTesting, 2)

        monitor.release(first)
        XCTAssertTrue(monitor.isRunningForTesting)
        XCTAssertEqual(monitor.activeLeaseCountForTesting, 1)

        monitor.release(second)
        XCTAssertFalse(monitor.isRunningForTesting)
        XCTAssertEqual(monitor.activeLeaseCountForTesting, 0)
    }

    func testStaleLeaseCannotStopNewGeneration() {
        let monitor = RuntimeActivityMonitor()

        let stale = monitor.acquire()
        monitor.release(stale)
        let current = monitor.acquire()

        monitor.release(stale)
        XCTAssertTrue(monitor.isRunningForTesting)
        XCTAssertEqual(monitor.activeLeaseCountForTesting, 1)

        monitor.release(current)
        XCTAssertFalse(monitor.isRunningForTesting)
    }

    func testLeaseReleaseIsIdempotent() {
        let monitor = RuntimeActivityMonitor()
        let first = monitor.acquire()
        let second = monitor.acquire()

        monitor.release(first)
        monitor.release(first)
        XCTAssertTrue(monitor.isRunningForTesting)
        XCTAssertEqual(monitor.activeLeaseCountForTesting, 1)

        monitor.release(second)
        XCTAssertFalse(monitor.isRunningForTesting)
    }
}

final class AppServicesLifecycleGateTests: XCTestCase {
    private enum ExpectedError: Error {
        case failure
    }

    @MainActor
    func testSuspendedOperationBlocksItsSuccessor() async {
        let services = AppServices()
        let firstEntered = expectation(description: "first operation entered")
        var releaseFirst: CheckedContinuation<Void, Never>?
        var events: [String] = []

        let firstTask = Task { @MainActor in
            await services.withLifecycleOperation {
                events.append("first-start")
                firstEntered.fulfill()
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                }
                events.append("first-end")
            }
        }

        await fulfillment(of: [firstEntered], timeout: 1)
        let secondTask = Task { @MainActor in
            await services.withLifecycleOperation {
                events.append("second")
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(events, ["first-start"])
        XCTAssertNotNil(releaseFirst)
        releaseFirst?.resume()
        await firstTask.value
        await secondTask.value
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }

    @MainActor
    func testThrownOperationReleasesGate() async {
        let services = AppServices()

        do {
            try await services.withLifecycleOperation {
                throw ExpectedError.failure
            }
            XCTFail("Expected lifecycle operation to throw")
        } catch ExpectedError.failure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        var successorRan = false
        await services.withLifecycleOperation {
            successorRan = true
        }
        XCTAssertTrue(successorRan)
    }
}
