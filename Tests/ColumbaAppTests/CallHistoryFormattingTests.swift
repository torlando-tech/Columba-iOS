import Foundation
import XCTest
import LXSTSwift
@testable import ColumbaApp

final class CallHistoryFormattingTests: XCTestCase {

    // MARK: day grouping

    func testDayGroupTodayAndYesterdayAndDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // a fixed "now"
        let today = now
        let yesterday = now.addingTimeInterval(-86_400)
        let older = now.addingTimeInterval(-3 * 86_400)
        let cal = Calendar.current
        func startOfDay(_ d: Date) -> Date {
            cal.dateInterval(of: .day, for: d)!.start
        }
        XCTAssertEqual(CallHistoryFormatting.dayKey(today, now: now),
                       CallHistoryFormatting.dayKey(today, now: now))
        XCTAssertNotEqual(CallHistoryFormatting.dayKey(today, now: now),
                          CallHistoryFormatting.dayKey(yesterday, now: now))
        XCTAssertEqual(
            CallHistoryFormatting.dayKey(yesterday, now: now),
            CallHistoryFormatting.dayKey(startOfDay(now.addingTimeInterval(-86_400)), now: now))
        XCTAssertNotEqual(CallHistoryFormatting.dayKey(older, now: now),
                          CallHistoryFormatting.dayKey(yesterday, now: now))
    }

    func testDayLabelTodayYesterdayAndMediumDate() {
        let now = Date()
        XCTAssertEqual(CallHistoryFormatting.dayLabel(Date(), now: now), "Today")
        let yest = now.addingTimeInterval(-86_400)
        XCTAssertEqual(CallHistoryFormatting.dayLabel(yest, now: now), "Yesterday")
        let older = now.addingTimeInterval(-9 * 86_400)
        // Older days render as a locale MEDIUM date (non-empty, not Today/Yesterday).
        let label = CallHistoryFormatting.dayLabel(older, now: now)
        XCTAssertNotEqual(label, "Today")
        XCTAssertNotEqual(label, "Yesterday")
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: duration

    func testConnectedDurationMinutesSeconds() {
        // 130 s -> "2:10"
        XCTAssertEqual(CallHistoryFormatting.duration(minutes: 2, seconds: 10), "2:10")
        XCTAssertEqual(CallHistoryFormatting.duration(minutes: 0, seconds: 5), "0:05")
        // Contradictory/unknown evidence -> "Unavailable" (do not guess, do not show 0:00).
        XCTAssertEqual(CallHistoryFormatting.unavailable, "Unavailable")
    }

    func testDurationFromMilestones() {
        let connected = Date(timeIntervalSince1970: 1_700_000_000)
        let ended = connected.addingTimeInterval(130)
        XCTAssertEqual(CallHistoryFormatting.connectedDuration(connected: connected,
                                                              ended: ended), "2:10")
        // No connection -> nil (a never-connected call shows NO duration, not 0:00).
        XCTAssertNil(CallHistoryFormatting.connectedDuration(connected: nil, ended: ended))
        // Contradictory (ended before connected) -> "Unavailable".
        XCTAssertNotEqual(CallHistoryFormatting.connectedDuration(connected: ended,
                                                                 ended: connected), nil)
    }

    // MARK: outcome mapping (direction x reason, gated on whether it connected)
    //
    // CRITICAL parity rule (mirrors the Android DAO): connectedAt is the decider.
    // A call that REACHED connectedAt finalizes as .connectedEnded regardless of the
    // terminal reason (a local hangup of a connected call is "Connected", NOT
    // "Cancelled"); only a genuine mid-call transport drop (.linkClosed) is
    // .interrupted. The CallEndReason only disambiguates calls that NEVER connected.

    func testOutcomeMappingWhenConnected() {
        // Connected -> connectedEnded for every reason EXCEPT a mid-call link drop.
        for r: CallEndReason in [.localHangup, .remoteHangup, .rejected, .busy,
                                 .ringTimeout, .connectTimeout] {
            XCTAssertEqual(CallHistoryFormatting.outcome(direction: .outgoing,
                                                        wasConnected: true, reason: r),
                           .connectedEnded, "connected outgoing + \(r)")
            XCTAssertEqual(CallHistoryFormatting.outcome(direction: .incoming,
                                                        wasConnected: true, reason: r),
                           .connectedEnded, "connected incoming + \(r)")
        }
        // A mid-call transport drop is the one connected-case exception.
        XCTAssertEqual(CallHistoryFormatting.outcome(direction: .outgoing,
                                                    wasConnected: true, reason: .linkClosed),
                       .interrupted)
    }

    func testOutcomeMappingWhenNeverConnected() {
        func out(_ dir: CallHistoryDirection, _ r: CallEndReason) -> CallOutcome {
            CallHistoryFormatting.outcome(direction: dir, wasConnected: false, reason: r)
        }
        // Incoming, never connected
        XCTAssertEqual(out(.incoming, .localHangup), .declinedLocal)      // user rejected
        XCTAssertEqual(out(.incoming, .rejected), .declinedLocal)         // (defensive)
        XCTAssertEqual(out(.incoming, .busy), .failed)
        XCTAssertEqual(out(.incoming, .ringTimeout), .missedIncoming)
        XCTAssertEqual(out(.incoming, .connectTimeout), .failed)
        XCTAssertEqual(out(.incoming, .linkClosed), .interrupted)
        // Outgoing, never connected
        XCTAssertEqual(out(.outgoing, .rejected), .rejectedRemote)
        XCTAssertEqual(out(.outgoing, .busy), .busyRemote)
        XCTAssertEqual(out(.outgoing, .ringTimeout), .notConnected)       // no answer
        XCTAssertEqual(out(.outgoing, .connectTimeout), .notConnected)    // no route
        XCTAssertEqual(out(.outgoing, .linkClosed), .interrupted)
        XCTAssertEqual(out(.outgoing, .localHangup), .cancelledLocal)     // user gave up pre-connect
    }

    // MARK: peer name fallback

    func testPeerNameFallbackFirst8HexUppercase() {
        // 16 bytes of 0xAB -> 32 hex chars "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        // fallback uses the first 4 bytes (8 hex chars) uppercased.
        let hash = Data(repeating: 0xAB, count: 16)
        XCTAssertEqual(CallHistoryFormatting.peerName(displayName: nil,
                                                      remoteIdentityHash: hash),
                       "Peer ABABABAB")
        XCTAssertEqual(CallHistoryFormatting.peerName(displayName: "",
                                                      remoteIdentityHash: hash),
                       "Peer ABABABAB")   // empty name == no name
        XCTAssertEqual(CallHistoryFormatting.peerName(displayName: "Ada",
                                                      remoteIdentityHash: hash), "Ada")
    }
}
