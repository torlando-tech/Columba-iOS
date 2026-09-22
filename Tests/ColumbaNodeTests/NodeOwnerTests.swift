import XCTest
import Foundation
@testable import ColumbaNode

/// Locks the node-owner coordinator (contract 6.5): the control protocol
/// (hello/admit/query/act) over the durable store + the pluggable engine. The
/// engine is a fake, so the test is hermetic + runs on any platform. It proves
/// the admission/execution split: admit commits the durable disposition,
/// execution runs outside that transaction, and the engine's domain change is
/// committed by the owner (the single writer for the node group).
final class NodeOwnerTests: XCTestCase {

    // MARK: - Fake engine (the seam, contract 15)

    /// A controllable fake engine. Records execute calls; configurable
    /// capability gate + execute outcome + domain change.
    private final class FakeEngine: NodeEngine, @unchecked Sendable {
        var buildInfo = BuildInfo(name: "fake", revision: "1", adapterRevision: "1")
        var capabilities: [Capability] = [
            Capability(feature: .durableMessaging, support: .supported, availability: .available, reason: nil),
        ]
        var canExecuteError: NodeError? = nil
        var executeResult: EngineCommandResult = .ok(EngineChange(entity: .message, key: "msg",
                                                                  identityID: nil, revision: Counter(1), removed: false))
        var executeThrows = false
        var startDescriptor: Descriptor? = nil
        var executeCalls: [CommandID] = []
        var startCalls = 0
        var stopCalls = 0

        func start(store: NodeStore) async throws -> Descriptor {
            startCalls += 1
            if let d = startDescriptor { return d }
            return Descriptor(version: .v1_0, storeEpoch: store.epochValue, bootID: BootID(),
                              storeSchema: 1, capabilities: capabilities, backend: buildInfo,
                              runtime: RuntimeSnapshot(bootID: BootID(), phase: .ready,
                                                      desiredEnabled: true, actualEnabled: true,
                                                      enabledIdentities: [], connectivity: .interfacesAvailable,
                                                      observedAt: Instant(date: Date())))
        }
        func stop() async { stopCalls += 1 }
        func runtimeSnapshot() async -> RuntimeSnapshot {
            RuntimeSnapshot(bootID: BootID(), phase: .ready, desiredEnabled: true, actualEnabled: true,
                            enabledIdentities: [], connectivity: .interfacesAvailable, observedAt: Instant(date: Date()))
        }
        func execute(_ intent: Intent) async throws -> EngineCommandResult {
            executeCalls.append(intent.commandID)
            if executeThrows { throw NodeError(code: .unavailable, message: "fake engine fault") }
            return executeResult
        }
        func canExecute(_ intent: Intent) -> NodeError? { canExecuteError }
    }

    // MARK: - fixtures

    private var store: NodeStore!
    private var engine: FakeEngine!
    private var owner: NodeOwner!
    private let identity = IdentityID()
    private let dest = DestinationHash(hex: "0123456789abcdef0123456789abcdef")!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(config: .inMemory)
        engine = FakeEngine()
        owner = NodeOwner(store: store, engine: engine)
    }

    private func submitIntent(commandID: CommandID, content: String = "hello") -> Intent {
        Intent(storeEpoch: store.epochValue, commandID: commandID, createdAt: Instant(1_000_000),
               body: .submitMessage(submit: SubmitMessage(
                   scope: Scope(identityID: identity),
                   destination: dest,
                   payload: .chat(ChatPayload(title: nil, content: content)),
                   delivery: DeliveryPolicy(preferred: .automatic, allowPropagationFallback: false,
                                            maxAttempts: NonNegative(3), stampBudgetMs: NonNegative(5000)),
                   deadline: nil)))
    }

    // Encode a framed control envelope for a request body.
    private func envelope(_ body: RequestBody) -> Data {
        try! ControlChannel.encode(request: body, requestID: RequestID())
    }

    private func session(boot: BootID) -> Session {
        Session(version: .v1_0, storeEpoch: store.epochValue, bootID: boot)
    }

    /// hello, capturing the returned descriptor.
    @MainActor
    private func hello() async throws -> Descriptor {
        let replyData = await owner.handle(envelope(.hello(versions: [.v1_0], schemaMin: 1, schemaMax: 1)))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .success(.hello(let d)) = reply.result else {
            XCTFail("hello did not return a descriptor")
            return Descriptor(version: .v1_0, storeEpoch: store.epochValue, bootID: BootID(),
                              storeSchema: 1, capabilities: [], backend: BuildInfo(name: "", revision: "", adapterRevision: ""),
                              runtime: RuntimeSnapshot(bootID: BootID(), phase: .failed, desiredEnabled: false,
                                                       actualEnabled: false, enabledIdentities: [], connectivity: .unknown,
                                                       observedAt: Instant(0)))
        }
        return d
    }

    // MARK: - tests

    @MainActor
    func testHelloReturnsDescriptorAndStartsEngine() async throws {
        let d = try await hello()
        XCTAssertEqual(d.capabilities.first?.feature, .durableMessaging)
        XCTAssertEqual(engine.startCalls, 1, "hello must start the engine for the boot")
        // The hello reply carries the storeEpoch + bootID the app echoes back.
        XCTAssertEqual(d.storeEpoch, store.epochValue)
    }

    @MainActor
    func testAdmitAcceptedThenExecutesAndCommitsChange() async throws {
        let d = try await hello()
        let cmd = CommandID()
        try store.stage(submitIntent(commandID: cmd))

        let replyData = await owner.handle(envelope(.admit(session: session(boot: d.bootID), commandID: cmd)))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .success(.admission(let record)) = reply.result else {
            return XCTFail("admit did not return an admission record")
        }
        XCTAssertEqual(record.disposition, .accepted)
        XCTAssertEqual(record.operationID?.wire, cmd.wire)
        // Execution ran OUTSIDE the admission transaction, after the record was
        // committed: the engine was called exactly once for this command.
        XCTAssertEqual(engine.executeCalls.map { $0.wire }, [cmd.wire])
        // The engine's domain change was committed by the owner (single writer).
        XCTAssertGreaterThanOrEqual(store.highWater().sequence.value, 2,
                                    "admit + engine change must advance the change index")
    }

    @MainActor
    func testAdmitRejectedByCapabilityGateNeverExecutes() async throws {
        let d = try await hello()
        engine.canExecuteError = NodeError(code: .featureDisabled, message: "no durableMessaging")
        let cmd = CommandID()
        try store.stage(submitIntent(commandID: cmd))

        let replyData = await owner.handle(envelope(.admit(session: session(boot: d.bootID), commandID: cmd)))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .success(.admission(let record)) = reply.result else {
            return XCTFail("admit did not return an admission record")
        }
        XCTAssertEqual(record.disposition, .rejected)
        XCTAssertTrue(record.rejection?.code == .featureDisabled, "rejection must carry the gate's typed error")
        // A rejected disposition is terminal: it NEVER executes.
        XCTAssertEqual(engine.executeCalls.count, 0)
    }

    @MainActor
    func testAdmitIsIdempotentReturnsCommittedDisposition() async throws {
        let d = try await hello()
        let cmd = CommandID()
        try store.stage(submitIntent(commandID: cmd))
        let body = RequestBody.admit(session: session(boot: d.bootID), commandID: cmd)

        let first = try ControlChannel.decodeReply(from: await owner.handle(envelope(body)))
        let second = try ControlChannel.decodeReply(from: await owner.handle(envelope(body)))
        guard case .success(.admission(let r1)) = first.result,
              case .success(.admission(let r2)) = second.result else {
            return XCTFail("expected two admission records")
        }
        XCTAssertEqual(r1.disposition, r2.disposition)
        // The ledger is checked FIRST: the second admit returns the committed
        // disposition and does NOT re-execute.
        XCTAssertEqual(engine.executeCalls.count, 1)
    }

    @MainActor
    func testQueryNodeStateReturnsLiveDescriptor() async throws {
        let d = try await hello()
        let replyData = await owner.handle(envelope(.query(session: session(boot: d.bootID), query: .nodeState)))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .success(.query(.nodeState(let desc))) = reply.result else {
            return XCTFail("nodeState query did not return a descriptor")
        }
        XCTAssertEqual(desc.bootID, d.bootID)
    }

    @MainActor
    func testQueryOperationAfterAdmitReturnsSucceeded() async throws {
        let d = try await hello()
        engine.executeResult = .ok(nil)   // no domain change, just success
        let cmd = CommandID()
        try store.stage(submitIntent(commandID: cmd))
        _ = await owner.handle(envelope(.admit(session: session(boot: d.bootID), commandID: cmd)))

        let opID = OperationID(cmd.raw)
        let replyData = await owner.handle(envelope(.query(session: session(boot: d.bootID), query: .operation(opID))))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .success(.query(.operation(let rec))) = reply.result else {
            return XCTFail("operation query did not return a record")
        }
        XCTAssertEqual(rec.state, .succeeded)
        XCTAssertEqual(rec.commandID, cmd)
    }

    @MainActor
    func testWrongStoreEpochIsRejected() async throws {
        let d = try await hello()
        // A request carrying a DIFFERENT store epoch than the live store is a
        // typed error, never a silent fallthrough (contract 6).
        let badEpoch = Session(version: .v1_0, storeEpoch: StoreEpoch(), bootID: d.bootID)
        let cmd = CommandID()
        try store.stage(submitIntent(commandID: cmd))
        let replyData = await owner.handle(envelope(.admit(session: badEpoch, commandID: cmd)))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .failure(let err) = reply.result else {
            return XCTFail("an out-of-epoch admit must fail")
        }
        XCTAssertEqual(err.code, .storeReplaced)
        // And it must NOT have executed.
        XCTAssertEqual(engine.executeCalls.count, 0)
    }

    @MainActor
    func testBootChangedIsRejected() async throws {
        let d = try await hello()
        // A request carrying a bootID from a PREVIOUS boot must fail with
        // bootChanged (the app must re-hello), not be served.
        let staleBoot = Session(version: .v1_0, storeEpoch: store.epochValue, bootID: BootID())
        let replyData = await owner.handle(envelope(.query(session: staleBoot, query: .nodeState)))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .failure(let err) = reply.result else {
            return XCTFail("a stale-boot query must fail")
        }
        XCTAssertEqual(err.code, .bootChanged)
    }

    @MainActor
    func testUnknownFramingVersionNeverFallsThrough() async throws {
        // 0xF5 but a wrong version byte: a HARD control-protocol error. It must
        // reply a typed failure, never be treated as legacy IPC (contract 6).
        let badEnvelope = Data([0xF5, 0x99, 0x7B, 0x7D])   // [0xF5 0x99] + "{}"
        let replyData = await owner.handle(badEnvelope)
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .failure(let err) = reply.result else {
            return XCTFail("an unknown framing version must fail")
        }
        XCTAssertEqual(err.code, .protocolFailure)
    }

    @MainActor
    func testActStopCallsEngineStop() async throws {
        let d = try await hello()
        XCTAssertEqual(engine.stopCalls, 0)
        let replyData = await owner.handle(envelope(.act(session: session(boot: d.bootID), actionID: ActionID(), action: .stop)))
        let reply = try ControlChannel.decodeReply(from: replyData)
        guard case .success(.action(.unit)) = reply.result else {
            return XCTFail("stop did not return unit")
        }
        XCTAssertEqual(engine.stopCalls, 1)
    }
}
