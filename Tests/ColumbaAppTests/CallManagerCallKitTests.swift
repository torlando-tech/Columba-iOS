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
