//
//  CallManagerCallKitTests.swift
//  ColumbaAppTests
//
//  Verifies that CallManager invokes CallKit only after the LXST identify
//  exchange completes — not on bare link establishment. The pre-fix
//  behavior fired the system call UI for every inbound link to the
//  telephony destination, which surfaced as phantom "Unknown" calls when
//  scanners / probes / aborted dials opened a link without ever
//  identifying themselves.
//

#if os(iOS)

import CallKit
import Foundation
import RNSAPI
import XCTest

@testable import ColumbaApp

@available(iOS 17.0, *)
@MainActor
final class CallManagerCallKitTests: XCTestCase {

    // MARK: - Bug reproduction

    /// Bare link establishment must NOT report an incoming call to CallKit.
    ///
    /// Per LXST protocol, the link being open just means "we have a secure
    /// pipe". The callee sends `STATUS_AVAILABLE`, waits for the caller to
    /// `link.identify(...)`, and only then is there a real call to ring.
    /// Reporting to CallKit before identify shows phantom calls for any
    /// peer that opens a link without intending to talk (probes, retries,
    /// scanners, aborted dials).
    func test_prepareForIncomingCall_doesNotReportToCallKit() {
        let mock = MockCallKitReporter()
        let manager = CallManager()
        manager.callKitManager = mock

        // Simulate the side effects of a link being established for an
        // incoming call. This is the part of `handleIncomingLink` that
        // sets local state — the actual `Link` handoff to the Telephone
        // actor (which then runs the AVAILABLE / identify protocol) is
        // verified by integration tests, not here.
        manager.prepareForIncomingCall()

        XCTAssertEqual(
            mock.reportIncomingCallInvocations.count,
            0,
            "CallKit must not be invoked on link establishment alone — caller has not yet identified"
        )
        // State setup that should happen on link establishment
        XCTAssertTrue(manager.isIncoming, "isIncoming should be set so the ringing callback can route correctly")
        XCTAssertEqual(manager.callState, .connecting, "callState should reflect the in-progress link setup")
        XCTAssertNotNil(manager.currentCallUUID, "A UUID must be allocated up front so the later CallKit report has one")
    }

    // MARK: - Post-identify path

    /// Once the caller has identified, the ringing path MUST report the
    /// incoming call to CallKit.
    ///
    /// This is the protocol-correct moment to invoke CallKit: we have a
    /// verified `Identity`, the system call UI can show a real caller
    /// (with a resolvable name), and the user's tap on Answer/Decline
    /// is mapped onto a meaningful peer.
    func test_handleCallerIdentified_reportsIncomingCallToCallKit_forIncomingCall() {
        let mock = MockCallKitReporter()
        let manager = CallManager()
        manager.callKitManager = mock

        // Set up state as if a link has been established (previous step)
        manager.prepareForIncomingCall()
        let allocatedUUID = manager.currentCallUUID

        // Simulate the caller having identified (post-AVAILABLE/IDENTIFY exchange)
        let stubHash = Data(repeating: 0xAB, count: 16)
        manager.handleCallerIdentified(stubHash)

        XCTAssertEqual(
            mock.reportIncomingCallInvocations.count,
            1,
            "CallKit must be reported exactly once after caller identifies"
        )
        XCTAssertEqual(
            mock.reportIncomingCallInvocations.first?.uuid,
            allocatedUUID,
            "CallKit report should reuse the UUID allocated at link-establishment time"
        )
        XCTAssertEqual(manager.callState, .ringing, "callState should transition to ringing on identify")
        XCTAssertEqual(manager.peerHash, stubHash.toHex(), "peerHash should be set to the identified caller")
    }

    /// Outgoing calls handle the ringing callback differently — they
    /// report to CallKit via `reportOutgoingCall`, NOT
    /// `reportIncomingCall`. The post-identify path must respect the
    /// `isIncoming` flag.
    func test_handleCallerIdentified_reportsOutgoingCall_forOutgoingCall() {
        let mock = MockCallKitReporter()
        let manager = CallManager()
        manager.callKitManager = mock

        // Outgoing calls don't go through prepareForIncomingCall;
        // they're set up via `call(...)` which sets isIncoming = false
        // and pre-allocates a UUID.
        manager.isIncoming = false
        let outgoingUUID = UUID()
        manager.currentCallUUID = outgoingUUID

        let stubHash = Data(repeating: 0xAB, count: 16)
        manager.handleCallerIdentified(stubHash)

        XCTAssertEqual(
            mock.reportIncomingCallInvocations.count,
            0,
            "Outgoing calls must not be reported as incoming"
        )
        XCTAssertEqual(
            mock.reportOutgoingCallInvocations.count,
            1,
            "Outgoing calls must be reported via reportOutgoingCall when remote rings"
        )
        XCTAssertEqual(
            mock.reportOutgoingCallInvocations.first,
            outgoingUUID,
            "reportOutgoingCall should reuse the UUID allocated when the call was placed"
        )
    }

    /// If the call is reset (abort, remote hangup) between
    /// `prepareForIncomingCall` and the LXST identify completing, the
    /// `currentCallUUID` may be nil by the time the ringing callback
    /// fires. The post-identify path must skip CallKit instead of
    /// crashing or invoking with a stale UUID.
    func test_handleCallerIdentified_skipsCallKit_whenUUIDClearedByReset() {
        let mock = MockCallKitReporter()
        let manager = CallManager()
        manager.callKitManager = mock

        manager.prepareForIncomingCall()
        // Simulate `resetState()` running mid-flight (e.g. user dismissed
        // an in-app surface, or a hangup raced identify). resetState
        // clears the UUID *and* drops callState back to .idle — both
        // need to be reflected here, otherwise the test only exercises
        // the `.connecting → no-change` transition and misses the
        // dangerous `.idle → .ringing` regression that motivated
        // hoisting the UUID guard to the top of handleCallerIdentified.
        manager.currentCallUUID = nil
        manager.callState = .idle

        let stubHash = Data(repeating: 0xAB, count: 16)
        manager.handleCallerIdentified(stubHash)

        XCTAssertEqual(
            mock.reportIncomingCallInvocations.count,
            0,
            "CallKit must not be invoked once the call's UUID has been reset"
        )
        // callState must NOT be flipped to .ringing on a reset-race —
        // doing so would leave the in-app UI stuck on ringing with no
        // CallKit registration to drive a dismissal.
        XCTAssertEqual(
            manager.callState,
            .idle,
            "callState must not advance to .ringing when the UUID has been cleared by a reset race"
        )
        XCTAssertNil(manager.peerHash, "peerHash must not be populated on a reset-race")
    }

    // MARK: - Call-history lifecycle finalization (issue #167)

    /// A CallKit provider reset while a call is active must FINALIZE the
    /// history attempt (end time + outcome) — otherwise the row is stranded
    /// with no end and the Voice list shows a dead call "in progress" forever.
    /// Regression: pre-fix, `handleCallKitReset` → `resetState` cleared
    /// `currentCallAttemptId` without writing `recordEnd`.
    func test_handleCallKitReset_finalizesActiveHistoryAttempt() async throws {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("callhist-reset-\(UUID().uuidString).db")
        let repo = try CallHistoryRepository(grdbPath: dbURL.path)
        let manager = CallManager()
        manager.callKitManager = MockCallKitReporter()
        manager.callHistoryRepository = repo
        manager.localIdentityHashHex = String(repeating: "b", count: 32)
        defer {
            // (No explicit close: the actor pool tears down on suspension /
            // deinit — same convention as CallHistoryRepositoryTests.)
            manager.callHistoryRepository = nil
        }

        // An in-flight incoming call (prepared + identified = attempt started).
        manager.prepareForIncomingCall()
        manager.handleCallerIdentified(Data(repeating: 7, count: 20))
        let attemptId = try XCTUnwrap(manager.currentCallAttemptId)

        // Provider reset with the call still live.
        manager.handleCallKitReset()

        // The reset path finalizes the attempt: poll for the end time.
        var record: CallHistoryRecord?
        let idHex = String(repeating: "b", count: 32)
        for _ in 0..<100 {
            record = try await repo.fetchRecord(attemptId, localIdentityHash: idHex)
            if record?.endedAt != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let final = try XCTUnwrap(record, "history row missing after reset")
        XCTAssertNotNil(final.endedAt, "reset must finalize the attempt with an end time")
        XCTAssertEqual(final.outcome, .notConnected,
                       "a reset before the connection milestone records notConnected")
    }

    /// A reset with NO active call must not write anything (and a second
    /// reset after the first is a no-op — exactly-once finalization).
    func test_handleCallKitReset_withNoActiveCall_writesNoHistory() async throws {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("callhist-reset2-\(UUID().uuidString).db")
        let repo = try CallHistoryRepository(grdbPath: dbURL.path)
        let manager = CallManager()
        manager.callKitManager = MockCallKitReporter()
        manager.callHistoryRepository = repo
        manager.localIdentityHashHex = String(repeating: "b", count: 32)
        defer {
            // (No explicit close: the actor pool tears down on suspension /
            // deinit — same convention as CallHistoryRepositoryTests.)
            manager.callHistoryRepository = nil
        }

        let idHex = String(repeating: "b", count: 32)
        manager.handleCallKitReset()
        try await Task.sleep(for: .milliseconds(300))
        manager.handleCallKitReset()  // double reset must stay a no-op
        try await Task.sleep(for: .milliseconds(300))

        let records = try await repo.fetchHistory(localIdentityHash: idHex, query: "")
        XCTAssertEqual(records.count, 0, "no call in flight → no history rows")
    }

    /// `shutdown()` must DRAIN the history-write chain before returning:
    /// AppServices closes this manager's repository immediately after
    /// shutdown() (identity switch), so a write still queued when shutdown
    /// returns is silently lost. Regression: the stale-repository fix closed
    /// the old repo without draining, so a shutdown mid-call discarded the
    /// pending attempt write.
    func test_shutdown_drainsPendingHistoryWritesBeforeReturning() async throws {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("callhist-shutdown-\(UUID().uuidString).db")
        let repo = try CallHistoryRepository(grdbPath: dbURL.path)
        let manager = CallManager()
        manager.callKitManager = MockCallKitReporter()
        manager.callHistoryRepository = repo
        manager.localIdentityHashHex = String(repeating: "b", count: 32)
        defer { manager.callHistoryRepository = nil }

        // In-flight incoming call → attempt insert enqueued onto the chain.
        manager.prepareForIncomingCall()
        manager.handleCallerIdentified(Data(repeating: 7, count: 20))
        let attemptId = try XCTUnwrap(manager.currentCallAttemptId)

        // Shutdown right after the insert is enqueued (insert may not have
        // executed yet). Pre-fix, the pending write was lost when the repo
        // closed; post-fix the drain awaits it.
        await manager.shutdown()

        var record: CallHistoryRecord?
        let idHex = String(repeating: "b", count: 32)
        for _ in 0..<50 {
            record = try await repo.fetchRecord(attemptId, localIdentityHash: idHex)
            if record != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try XCTUnwrap(record,
                           "shutdown must drain the pending attempt write before the repository closes")
    }
}

// MARK: - Mock

/// Records every CallKit invocation. Test target uses this in place of
/// the real `CallKitManager` to assert call ordering / count.
@available(iOS 17.0, *)
final class MockCallKitReporter: CallKitReporting {
    struct ReportIncoming { let uuid: UUID; let peerName: String? }

    var reportIncomingCallInvocations: [ReportIncoming] = []
    var reportOutgoingCallInvocations: [UUID] = []
    var reportCallConnectedInvocations: [UUID] = []
    var reportCallEndedInvocations: [(UUID, CXCallEndedReason)] = []
    var updateCallerNameInvocations: [(UUID, String)] = []
    var startCallInvocations: [(UUID, String)] = []
    var answerCallInvocations: [UUID] = []
    var endCallInvocations: [UUID] = []

    func reportIncomingCall(uuid: UUID, peerName: String?, completion: @escaping (Error?) -> Void) {
        reportIncomingCallInvocations.append(.init(uuid: uuid, peerName: peerName))
        completion(nil)
    }
    func updateCallerName(uuid: UUID, name: String) {
        updateCallerNameInvocations.append((uuid, name))
    }
    func reportOutgoingCall(uuid: UUID) {
        reportOutgoingCallInvocations.append(uuid)
    }
    func reportCallConnected(uuid: UUID) {
        reportCallConnectedInvocations.append(uuid)
    }
    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason) {
        reportCallEndedInvocations.append((uuid, reason))
    }
    func startCall(uuid: UUID, handle: String) {
        startCallInvocations.append((uuid, handle))
    }
    func answerCall(uuid: UUID) {
        answerCallInvocations.append(uuid)
    }
    func endCall(uuid: UUID) {
        endCallInvocations.append(uuid)
    }
}

#endif
