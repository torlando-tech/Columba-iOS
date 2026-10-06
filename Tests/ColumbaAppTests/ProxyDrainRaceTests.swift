import XCTest
import Foundation
import RNSAPI
@testable import ColumbaModelBApp

/// P2 #1 (ne-python-architecture-review): event-drain shutdown race.
///
/// `ProxyRnsBackend.requestDrain` spawns an UNTRACKED `Task` that calls
/// `drainNow()`, which `await`s the `.drainEvents` IPC round-trip and then
/// mutates `lastSeenAnnounce` + yields events. If a `stop()` lands while that
/// IPC is in flight, the suspended worker resumes after the stop and:
///   1. writes `lastSeenAnnounce` for a node that is stopped (state resurrected),
///   2. yields events onto the stream for a stopped node,
///   3. a later `start()` can then run a concurrent second drain.
///
/// The fix invalidates the drain by generation across the IPC await (a `stop()`
/// bumps `startGeneration`), so a stale drain discards its payload instead of
/// yielding, and serializes the `lastSeenAnnounce` access.
///
/// These tests drive the REAL `ProxyRnsBackend` through its injectable `send`
/// transport: the stub suspends the `.drainEvents` reply so the test can interleave
/// a `stop()` while the drain is suspended, then release the held reply. The
/// public `events` stream is the observation surface.
final class ProxyDrainRaceTests: XCTestCase {

    // MARK: - IPC reply latch (control the drainEvents reply from the test)

    /// Lets the test (a) know the drain worker has reached the `.drainEvents`
    /// await, and (b) resolve the held reply at a controlled moment. The same
    /// object is shared with the injected `send` closure.
    private final class DrainGate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var exitReply: Data?
        private var exitCont: CheckedContinuation<Data?, Never>?
        private var exiting = false

        /// Called by the stub when a `.drainEvents` request arrives. Returns the
        /// reply the test eventually resolves, suspending until then.
        func request() async -> Data? {
            lock.lock()
            entered = true
            lock.unlock()
            return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                lock.lock()
                if exiting, let reply = exitReply {
                    // Already resolved before the worker parked - resume now.
                    exitReply = nil
                    lock.unlock()
                    cont.resume(returning: reply)
                    return
                }
                exitCont = cont
                lock.unlock()
            }
        }

        /// True once the drain worker has hit the `.drainEvents` await (within the
        /// timeout). Polls so a missing drain fails the test instead of hanging.
        func waitEntered(timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() <= deadline {
                lock.lock()
                let e = entered
                lock.unlock()
                if e { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            lock.lock(); let e = entered; lock.unlock()
            return e
        }

        func resolve(_ reply: Data?) {
            lock.lock()
            exiting = true
            if let cont = exitCont {
                exitCont = nil
                lock.unlock()
                cont.resume(returning: reply)
            } else {
                exitReply = reply
                lock.unlock()
            }
        }
    }

    // MARK: - stub + payload builders

    private func stub(_ gate: DrainGate) -> @Sendable (Data) async -> Data? {
        return { wire in
            guard let req = try? ProxyIPC.decodeRequest(wire) else { return nil }
            switch req {
            case .start:
                let info = ProxyLocalInfo(identityHash: "11".padding(toLength: 64, withPad: "0", startingAt: 0),
                                          destinationHash: "22".padding(toLength: 64, withPad: "0", startingAt: 0))
                return ProxyIPC.encodeResponse(.ok(try? JSONEncoder().encode(info)))
            case .drainEvents:
                return await gate.request()
            default:
                return ProxyIPC.encodeResponse(.unsupported)
            }
        }
    }

    private func announcePayload() -> Data {
        let e = ProxyEvent(kind: "announce",
                           t: 1_700_000_000.0,
                           destHashHex: "ab".padding(toLength: 64, withPad: "0", startingAt: 0),
                           appDataHex: "00",
                           aspect: "",
                           publicKeysHex: "00",
                           interfaceName: "ble",
                           hops: 0)
        // The NE replies with a full ProxyResponse envelope (.ok carrying the
        // JSON [ProxyEvent] array); drainNow decodes the envelope then the array.
        return ProxyIPC.encodeResponse(.ok((try? JSONEncoder().encode([e])) ?? Data()))
    }

    private func isAnnounce(_ e: BackendEvent) -> Bool {
        if case .announce = e { return true }
        return false
    }

    private func startParams() -> StartParams {
        StartParams(configDir: "/tmp/drain-race", identityPath: "/tmp/drain-race/identity", displayName: "t")
    }

    private func waitForEvents(_ events: () -> [BackendEvent], atLeast n: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            if events().count >= n { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return events().count >= n
    }

    // MARK: - tests

    /// Positive control: with NO stop, a drained announce is yielded on the stream.
    /// Proves the pipeline works, so the stale-drain test's "no event" is meaningful.
    func testLiveDrainYieldsAnnounce() async throws {
        let gate = DrainGate()
        let backend = ProxyRnsBackend(send: stub(gate))
        var events: [BackendEvent] = []
        let lock = NSLock()
        let consumer = Task {
            for await e in backend.events { lock.lock(); events.append(e); lock.unlock() }
        }
        gate.resolve(announcePayload())
        _ = try await backend.start(startParams())
        let got = await waitForEvents({ lock.lock(); let c = events; lock.unlock(); return c }, atLeast: 1)
        consumer.cancel()
        XCTAssertTrue(got, "a live drain should yield the announce")
        XCTAssertTrue(events.contains(where: isAnnounce), "expected an announce event, got \(events)")
    }

    /// THE regression: a drain suspended across the `.drainEvents` IPC, then a
    /// `stop()`, then the held reply released. A fixed backend must NOT yield the
    /// stale event (the node is stopped).
    func testStaleDrainDoesNotYieldAfterStop() async throws {
        let gate = DrainGate()
        let backend = ProxyRnsBackend(send: stub(gate))
        var events: [BackendEvent] = []
        let lock = NSLock()
        let consumer = Task {
            for await e in backend.events { lock.lock(); events.append(e); lock.unlock() }
        }
        _ = try await backend.start(startParams())

        // Wait until the initial drain worker is suspended at the `.drainEvents` await.
        let reached = await gate.waitEntered(timeout: 5)
        XCTAssertTrue(reached, "the initial drain should have reached the drainEvents IPC await")

        // Stop the backend while the drain reply is still held in flight.
        await backend.stop()

        // Now release the held reply with an announce.
        gate.resolve(announcePayload())

        // Give any (buggy) stale drain time to (incorrectly) yield.
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()
        lock.lock(); let snapshot = events; lock.unlock()
        XCTAssertFalse(snapshot.contains(where: isAnnounce),
                       "a drain that resumed after stop() must not yield events (stale incarnation): \(snapshot)")
    }
}
