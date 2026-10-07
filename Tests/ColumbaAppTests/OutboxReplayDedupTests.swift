import XCTest
import Foundation
@testable import ColumbaModelBApp

/// P1 #3 (stranded sends) + P1 #6 (send-response ambiguity) - the pure,
/// unit-testable seam: `OutboxReplayCoordinator.pendingReplays()` must drain the
/// outbox and return ONLY the entries that still need sending. An entry whose
/// stable `sendId` the NE already recorded is dropped (the double-send the review
/// warns about: a lost live reply makes the app re-enqueue the SAME id, and a
/// naive "unconditional drain" would then send it twice). A nil-id entry
/// (pre-migration / unknown) is always a replay target.
///
/// Each test gets its OWN backing files (a unique `name` under the tmp fallback,
/// since the App-Group container is absent on the simulator) so tests are
/// hermetic and order-independent.
final class OutboxReplayDedupTests: XCTestCase {

    /// An isolated coordinator whose outbox + sent-id store live in fresh, unique
    /// temp files (the `name` differs per call; an invalid app group forces the
    /// tmp fallback deterministically on the simulator).
    private func isolated() -> OutboxReplayCoordinator {
        let name = UUID().uuidString
        return OutboxReplayCoordinator(
            queue: OutboxQueue(appGroupIdentifier: "group.test.nonexistent", name: "ob-\(name)"),
            sentIds: SentIdStore(appGroupIdentifier: "group.test.nonexistent", name: "si-\(name)")
        )
    }

    private func entry(sendId: String?, content: String = "hi") -> OutboxEntry {
        OutboxEntry(
            destHashHex: "aa".padding(toLength: 64, withPad: "0", startingAt: 0),
            content: content,
            method: "opportunistic",
            fieldsData: nil,
            messageHashHex: nil,
            sendId: sendId,
            createdAt: 1_700_000_000.0
        )
    }

    /// A sendId the NE has not recorded yet is a replay target.
    func testUnrecordedIdIsReplayed() {
        let coord = isolated()
        coord.queue.append(entry(sendId: "id-1"))
        let pending = coord.pendingReplays()
        XCTAssertEqual(pending.count, 1, "an unrecorded id should be replayed")
        XCTAssertEqual(pending.first?.sendId, "id-1")
    }

    /// THE double-send guard: after the NE records an id, re-enqueuing the SAME
    /// id (a lost live reply -> the app queued it again) must NOT be replayed.
    func testRecordedIdIsNotReplayedAgain() {
        let coord = isolated()
        coord.queue.append(entry(sendId: "id-2", content: "first"))
        // First drain: it is pending (not yet sent).
        XCTAssertEqual(coord.pendingReplays().count, 1)
        // NE sends it -> records the id.
        coord.markSent("id-2")
        // The live reply was lost, so the app re-enqueued the SAME id.
        coord.queue.append(entry(sendId: "id-2", content: "dup"))
        // A correct coordinator must NOT replay it again.
        let pending = coord.pendingReplays()
        XCTAssertEqual(pending.count, 0, "an already-sent id must not be replayed (double-send guard): \(pending)")
    }

    /// A pre-migration / unknown entry (no stable id) is always a replay target.
    func testNilIdIsAlwaysReplayed() {
        let coord = isolated()
        coord.queue.append(entry(sendId: nil))
        XCTAssertEqual(coord.pendingReplays().count, 1, "a nil-id entry should be replayed")
    }

    /// Distinct unrecorded ids all replay; recording one drops only that one.
    func testMixedIdsReplayOnlyUnsent() {
        let coord = isolated()
        coord.queue.append(entry(sendId: "a"))
        coord.queue.append(entry(sendId: "b"))
        coord.queue.append(entry(sendId: nil))
        coord.markSent("b")
        let pending = coord.pendingReplays()
        XCTAssertEqual(pending.count, 2, "only the unrecorded ids replay: \(pending.map { $0.sendId ?? "nil" })")
        XCTAssertEqual(Set(pending.compactMap { $0.sendId }), ["a"])
    }
}
