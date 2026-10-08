import XCTest
import Foundation
@testable import ColumbaNode

/// Locks the durable stage-first admission + command-ledger semantics (contract 3):
/// idempotent re-staging, body-conflict detection, ledger-first admit, reject
/// disposition, abandon-before-admission, epoch replacement, and change-index
/// ordering. These run against an in-memory store so they are fast + hermetic.
final class StageAdmissionTests: XCTestCase {

    private var store: NodeStore!
    private let epoch = StoreEpoch()
    private let identity = IdentityID()

    private func submitIntent(commandID: CommandID, content: String = "hello",
                              created: Int64 = 1_000_000) -> Intent {
        Intent(storeEpoch: epoch, commandID: commandID, createdAt: Instant(created),
               body: .submitMessage(submit: SubmitMessage(
                   scope: Scope(identityID: identity),
                   destination: DestinationHash(hex: "0123456789abcdef0123456789abcdef")!,
                   payload: .chat(ChatPayload(title: nil, content: content)),
                   delivery: DeliveryPolicy(preferred: .automatic, allowPropagationFallback: false,
                                            maxAttempts: NonNegative(3), stampBudgetMs: NonNegative(5000)),
                   deadline: nil)))
    }

    override func setUp() {
        super.setUp()
        store = try! NodeStore(config: .inMemory)
        // A fresh store mints its own epoch; align the test epoch with it.
        _ = epoch   // placeholder; tests use the store's actual epoch below
    }

    private func aligned(_ intent: Intent) -> Intent {
        Intent(storeEpoch: store.epochValue, commandID: intent.commandID, createdAt: intent.createdAt,
               expiresAt: intent.expiresAt, afterCommandID: intent.afterCommandID, body: intent.body)
    }

    func testStageFreshAssignsStableIds() throws {
        let cmd = CommandID()
        let intent = aligned(submitIntent(commandID: cmd))
        let out = try store.stage(intent)
        guard case .staged(let r) = out else { return XCTFail("expected staged") }
        XCTAssertEqual(r.commandID, cmd)
        // MessageID + OperationID == CommandID (distinct types), per contract 3.1.
        XCTAssertEqual(r.messageID?.wire, cmd.wire)
        XCTAssertEqual(r.operationID.wire, cmd.wire)
        XCTAssertNotNil(r.localSequence, "a message command must get a LocalSequence")
        XCTAssertEqual(r.state, .staged)
    }

    func testIdempotentRestageSameBody() throws {
        let cmd = CommandID()
        let intent = aligned(submitIntent(commandID: cmd, content: "hello"))
        let first = try store.stage(intent)
        let second = try store.stage(intent)   // same key + same canonical body
        guard case .staged(let r1) = first, case .staged(let r2) = second else {
            return XCTFail("expected two staged receipts")
        }
        XCTAssertEqual(r1.commandID, r2.commandID)
        XCTAssertEqual(r1.messageID, r2.messageID, "re-stage must return the ORIGINAL receipt")
        XCTAssertEqual(r1.localSequence, r2.localSequence, "no second LocalSequence for the same logical send")
    }

    func testRestageDifferentBodyConflicts() throws {
        let cmd = CommandID()
        _ = try store.stage(aligned(submitIntent(commandID: cmd, content: "hello")))
        let out = try store.stage(aligned(submitIntent(commandID: cmd, content: "DIFFERENT")))
        guard case .conflict(let err) = out else { return XCTFail("expected a body conflict") }
        XCTAssertEqual(err.code, .idempotencyConflict)
    }

    func testAdmitAcceptThenLedgerFirst() throws {
        let cmd = CommandID()
        _ = try store.stage(aligned(submitIntent(commandID: cmd)))
        // First admit: policy accepts.
        let accept = try store.admit(commandID: cmd) { intent in .accept(operationID: OperationID(intent.commandID.raw)) }
        XCTAssertEqual(accept.disposition, .accepted)
        XCTAssertEqual(accept.operationID?.wire, cmd.wire)
        // Second admit with a policy that would REJECT: the ledger already has a
        // disposition, so it returns the EXISTING accepted record (contract 3.3)
        // and must NOT be re-evaluated by the new policy.
        let reAdmit = try store.admit(commandID: cmd) { _ in .reject(NodeError(code: .featureDisabled)) }
        XCTAssertEqual(reAdmit.disposition, .accepted, "ledger-first: existing disposition wins over a changed policy")
        XCTAssertEqual(reAdmit.operationID?.wire, cmd.wire)
    }

    func testAdmitRejectDisposition() throws {
        let cmd = CommandID()
        _ = try store.stage(aligned(submitIntent(commandID: cmd)))
        let record = try store.admit(commandID: cmd) { _ in .reject(NodeError.identityUnknown(self.identity)) }
        XCTAssertEqual(record.disposition, .rejected)
        XCTAssertEqual(record.rejection?.code, .identityUnknown)
        XCTAssertEqual(record.operationID, nil)
    }

    func testAdmitUnstagedThrowsNotFound() throws {
        let cmd = CommandID()
        XCTAssertThrowsError(try store.admit(commandID: cmd) { _ in .accept(operationID: OperationID()) }) { error in
            guard let e = error as? NodeError else { return XCTFail("wrong error type") }
            XCTAssertEqual(e.code, .notFound)
        }
    }

    func testAbandonStagedButNotAccepted() throws {
        let staged = CommandID()
        _ = try store.stage(aligned(submitIntent(commandID: staged)))
        let abandoned = try store.abandonBeforeAdmission(staged)
        XCTAssertTrue(abandoned, "a staged (not accepted) intent must be abandonable")

        let accepted = CommandID()
        _ = try store.stage(aligned(submitIntent(commandID: accepted)))
        _ = try store.admit(commandID: accepted) { intent in .accept(operationID: OperationID(intent.commandID.raw)) }
        let notAbandoned = try store.abandonBeforeAdmission(accepted)
        XCTAssertFalse(notAbandoned, "an already-accepted operation cannot be abandoned (cancel is a new command)")
    }

    func testEpochMismatchRejects() throws {
        let cmd = CommandID()
        let foreign = Intent(storeEpoch: StoreEpoch(), commandID: cmd, createdAt: Instant(1),
                             body: .submitMessage(submit: SubmitMessage(
                                scope: Scope(identityID: identity),
                                destination: DestinationHash(hex: "0123456789abcdef0123456789abcdef")!,
                                payload: .chat(ChatPayload(content: "x")),
                                delivery: DeliveryPolicy(preferred: .automatic, allowPropagationFallback: false,
                                                         maxAttempts: NonNegative(1), stampBudgetMs: NonNegative(0)),
                                deadline: nil)))
        XCTAssertThrowsError(try store.stage(foreign)) { error in
            XCTAssertEqual((error as? NodeError)?.code, .storeReplaced)
        }
    }

    func testChangeIndexOrdering() throws {
        // Stage three messages, admit the first; the change index must carry them
        // in commit order (stage order).
        let a = CommandID(), b = CommandID(), c = CommandID()
        _ = try store.stage(aligned(submitIntent(commandID: a)))
        _ = try store.stage(aligned(submitIntent(commandID: b)))
        _ = try store.stage(aligned(submitIntent(commandID: c)))
        _ = try store.admit(commandID: a) { intent in .accept(operationID: OperationID(intent.commandID.raw)) }
        let zero = Cursor(storeEpoch: store.epochValue, sequence: Counter(0))
        let txns = try store.changes(after: zero)
        // Each node transaction is a distinct sequence; the high-water cursor
        // reflects the latest committed sequence.
        let seqs = txns.map { $0.sequence.value }
        XCTAssertEqual(seqs, seqs.sorted(), "change index must be in commit order")
        XCTAssertFalse(seqs.isEmpty)
        // a message + a message + a message staged (3) + 1 admit op = at least 4 rows.
        let totalChanges = txns.reduce(0) { $0 + $1.changes.count }
        XCTAssertGreaterThanOrEqual(totalChanges, 4)
    }
}
