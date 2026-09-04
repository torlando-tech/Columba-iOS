import Foundation
import XCTest
@testable import ColumbaApp

final class CallHistoryRepositoryTests: XCTestCase {

    private var repo: CallHistoryRepository!
    private var dbURL: URL!
    private var idHex: String = ""

    override func setUpWithError() throws {
        // File-backed UNIQUE temp DB via the production init (the code under
        // test). An in-memory `DatabasePool` is NOT shared across its
        // connections in GRDB 6 — `useSingletonConnections` was removed — so
        // tests use a real file, which shares correctly.
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("callhist-\(UUID().uuidString).db")
        repo = try CallHistoryRepository(grdbPath: dbURL.path)
        idHex = String(repeating: "a", count: 32)
    }

    override func tearDownWithError() throws {
        // The actor is deallocated here; GRDB closes its pool on deinit, so no
        // explicit close() is needed (XCTest has no async tearDown to await one).
        try? FileManager.default.removeItem(at: dbURL)
    }

    func testInsertThenFetchRoundTrip() async throws {
        let id = "attempt-1"
        let remote = String(repeating: "b", count: 32)
        try await repo.insertAttempt(callAttemptId: id,
                                     localIdentityHash: idHex,
                                     remoteIdentityHash: remote,
                                     direction: .outgoing,
                                     peerDisplayNameSnapshot: "Bob",
                                     codecProfileCode: 0x40,
                                     attemptedAt: Date())
        let records = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].callAttemptId, id)
        XCTAssertEqual(records[0].direction, .outgoing)
        XCTAssertNil(records[0].endedAt)
        XCTAssertEqual(records[0].outcome, nil)
    }

    func testLifecycleMilestonesAndOutcome() async throws {
        let id = "attempt-2"
        let remote = String(repeating: "c", count: 32)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.insertAttempt(callAttemptId: id, localIdentityHash: idHex,
                                     remoteIdentityHash: remote, direction: .incoming,
                                     peerDisplayNameSnapshot: nil, codecProfileCode: nil,
                                     attemptedAt: t0)
        try await repo.recordConnected(id, at: t0.addingTimeInterval(20))
        try await repo.recordEnd(id, at: t0.addingTimeInterval(150), outcome: .connectedEnded)

        let records = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].connectedAt, t0.addingTimeInterval(20))
        XCTAssertEqual(records[0].endedAt, t0.addingTimeInterval(150))
        XCTAssertEqual(records[0].outcome, .connectedEnded)
        // Connected-only duration is derivable:
        XCTAssertEqual(CallHistoryFormatting.connectedDuration(
            connected: records[0].connectedAt, ended: records[0].endedAt), "2:10")
    }

    func testDuplicateInsertIsIgnored() async throws {
        let id = "attempt-3"
        let remote = String(repeating: "d", count: 32)
        for _ in 0..<2 {
            try await repo.insertAttempt(callAttemptId: id, localIdentityHash: idHex,
                                         remoteIdentityHash: remote, direction: .outgoing,
                                         peerDisplayNameSnapshot: nil, codecProfileCode: nil,
                                         attemptedAt: Date())
        }
        let records = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertEqual(records.count, 1)   // idempotent insert (INSERT OR IGNORE)
    }

    /// Exactly-once terminal: a second `recordEnd` for the same attempt must
    /// NOT clobber the stored outcome/end time (a duplicated end callback or a
    /// late stale reset must leave the first terminal write intact).
    func testDuplicateRecordEndIsIgnored() async throws {
        let id = "attempt-endx"
        try await repo.insertAttempt(callAttemptId: id, localIdentityHash: idHex,
                                     remoteIdentityHash: String(repeating: "a", count: 32),
                                     direction: .incoming, peerDisplayNameSnapshot: nil,
                                     codecProfileCode: nil,
                                     attemptedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await repo.recordEnd(id, at: Date(timeIntervalSince1970: 1_700_000_100),
                                 outcome: .declinedLocal)
        try await repo.recordEnd(id, at: Date(timeIntervalSince1970: 1_700_000_999),
                                 outcome: .notConnected)  // stale duplicate

        let records = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].outcome, .declinedLocal,
                       "the FIRST terminal write wins; a later recordEnd is a no-op")
        XCTAssertEqual(records[0].endedAt, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testNewestFirstOrdering() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(3600)
        try await repo.insertAttempt(callAttemptId: "old", localIdentityHash: idHex,
                                     remoteIdentityHash: String(repeating: "e", count: 32),
                                     direction: .outgoing, peerDisplayNameSnapshot: nil,
                                     codecProfileCode: nil, attemptedAt: old)
        try await repo.insertAttempt(callAttemptId: "new", localIdentityHash: idHex,
                                     remoteIdentityHash: String(repeating: "f", count: 32),
                                     direction: .incoming, peerDisplayNameSnapshot: nil,
                                     codecProfileCode: nil, attemptedAt: new)
        let records = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertEqual(records.map(\.callAttemptId), ["new", "old"])
    }

    func testSearchMatchesRemoteHashAndName() async throws {
        let remote = String(repeating: "0", count: 32)
        try await repo.insertAttempt(callAttemptId: "a", localIdentityHash: idHex,
                                     remoteIdentityHash: remote, direction: .outgoing,
                                     peerDisplayNameSnapshot: "Alice", codecProfileCode: nil,
                                     attemptedAt: Date())
        try await repo.insertAttempt(callAttemptId: "b", localIdentityHash: idHex,
                                     remoteIdentityHash: String(repeating: "1", count: 32),
                                     direction: .outgoing,
                                     peerDisplayNameSnapshot: "Bob", codecProfileCode: nil,
                                     attemptedAt: Date())
        let byName = try await repo.fetchHistory(localIdentityHash: idHex, query: "alice")
        XCTAssertEqual(byName.map(\.callAttemptId), ["a"])
        let byHash = try await repo.fetchHistory(localIdentityHash: idHex,
                                                 query: String(repeating: "0", count: 8))
        XCTAssertEqual(byHash.map(\.callAttemptId), ["a"])
        let none = try await repo.fetchHistory(localIdentityHash: idHex, query: "zzz")
        XCTAssertTrue(none.isEmpty)
    }

    func testIdentityScoping() async throws {
        let otherHex = String(repeating: "9", count: 32)
        try await repo.insertAttempt(callAttemptId: "mine", localIdentityHash: idHex,
                                     remoteIdentityHash: String(repeating: "2", count: 32),
                                     direction: .outgoing, peerDisplayNameSnapshot: nil,
                                     codecProfileCode: nil, attemptedAt: Date())
        try await repo.insertAttempt(callAttemptId: "theirs", localIdentityHash: otherHex,
                                     remoteIdentityHash: String(repeating: "3", count: 32),
                                     direction: .outgoing, peerDisplayNameSnapshot: nil,
                                     codecProfileCode: nil, attemptedAt: Date())
        let mine = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertEqual(mine.map(\.callAttemptId), ["mine"])
    }

    func testClearHistoryOnlyForIdentity() async throws {
        let otherHex = String(repeating: "9", count: 32)
        for (id, hex) in [("m1", idHex), ("m2", idHex), ("o1", otherHex)] {
            try await repo.insertAttempt(callAttemptId: id, localIdentityHash: hex,
                                         remoteIdentityHash: String(repeating: "4", count: 32),
                                         direction: .outgoing, peerDisplayNameSnapshot: nil,
                                         codecProfileCode: nil, attemptedAt: Date())
        }
        try await repo.clearHistory(localIdentityHash: idHex)
        let mine = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertTrue(mine.isEmpty)
        let theirs = try await repo.fetchHistory(localIdentityHash: otherHex, query: "")
        XCTAssertEqual(theirs.map(\.callAttemptId), ["o1"])
    }
}
