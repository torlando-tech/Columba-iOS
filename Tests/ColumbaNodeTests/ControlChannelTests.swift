import XCTest
import Foundation
@testable import ColumbaNode

/// Locks the bounded control channel + engine seam (contracts 6, 15): framing,
/// the 64 KiB cap, unknown-version hard failure, and hello/admit/query
/// round-trips. The last test exercises the contract 3.3 core: the command body
/// is NEVER inline - it is staged in the shared store, `admit` carries only the
/// commandID, and the node owner resolves it against the ledger.
final class ControlChannelTests: XCTestCase {

    // MARK: framing

    func testFramingRoundTrip() throws {
        let body = RequestBody.hello(versions: [.v1_0], schemaMin: 1, schemaMax: 1)
        let envelope = try ControlChannel.encode(request: body)
        // Magic bytes first.
        XCTAssertEqual([UInt8](envelope.prefix(2)), [0xF5, 0x02])
        // Decode back.
        let (id, decoded) = try ControlChannel.decodeRequest(from: envelope)
        _ = id
        guard case let .hello(versions, min, max) = decoded else {
            return XCTFail("expected hello, got \(decoded)")
        }
        XCTAssertEqual(versions, [.v1_0])
        XCTAssertEqual(min, 1)
        XCTAssertEqual(max, 1)
    }

    func testBadMagicRejected() {
        let envelope = Data([0x00, 0x02, 0x7b, 0x7d])
        XCTAssertThrowsError(try ControlChannel.payload(from: envelope)) { error in
            guard case .badMagic = error as? ControlChannelError else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testUnknownVersionRejectedAndNeverFallsThrough() {
        // 0xF5 with a version other than 0x02 is a hard control-protocol error.
        let envelope = Data([0xF5, 0x03, 0x7b, 0x7d])
        XCTAssertThrowsError(try ControlChannel.payload(from: envelope)) { error in
            guard case .unknownFramingVersion = error as? ControlChannelError else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testOversizeEnvelopeRejected() {
        // 64 KiB cap includes the 2 framing bytes, so a 65535-byte payload overflows.
        let bigPayload = Data(repeating: 0x7b, count: Int(ControlChannel.maxEnvelopeBytes - 1))
        XCTAssertThrowsError(try ControlChannel.frame(payload: bigPayload)) { error in
            guard case .oversize = error as? ControlChannelError else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    // MARK: admit round-trip + the stage-then-admit flow (contract 3.3)

    private func submitIntent(store: NodeStore, commandID: CommandID, content: String = "hello") -> Intent {
        Intent(storeEpoch: store.epochValue, commandID: commandID, createdAt: Instant(2_000_000),
               body: .submitMessage(submit: SubmitMessage(
                   scope: Scope(identityID: IdentityID()),
                   destination: DestinationHash(hex: "0123456789abcdef0123456789abcdef")!,
                   payload: .chat(ChatPayload(title: nil, content: content)),
                   delivery: DeliveryPolicy(preferred: .automatic, allowPropagationFallback: false,
                                            maxAttempts: NonNegative(3), stampBudgetMs: NonNegative(5000)),
                   deadline: nil)))
    }

    func testAdmitCarriesOnlyCommandIDNotBody() throws {
        let store = try NodeStore(config: .inMemory)
        let cmd = CommandID()
        let intent = submitIntent(store: store, commandID: cmd, content: "secret body content")
        _ = try store.stage(intent)

        let session = Session(version: .v1_0, storeEpoch: store.epochValue, bootID: BootID())
        let envelope = try ControlChannel.encode(request: .admit(session: session, commandID: cmd))
        let json = String(decoding: try ControlChannel.payload(from: envelope), as: UTF8.self)

        // The wire payload must reference the commandID but must NOT carry the
        // staged body inline (contract 3.3, 6).
        XCTAssertTrue(json.contains(cmd.wire))
        XCTAssertFalse(json.contains("secret body content"),
                       "the complete command body must never be sent inline")

        // Decode.
        let (requestID, decoded) = try ControlChannel.decodeRequest(from: envelope)
        _ = requestID
        guard case let .admit(ds, dcmd) = decoded else {
            return XCTFail("expected admit, got \(decoded)")
        }
        XCTAssertEqual(dcmd, cmd)
        XCTAssertEqual(ds.storeEpoch, store.epochValue)
    }

    func testStageAdmitResolveThroughLedger() throws {
        let store = try NodeStore(config: .inMemory)
        let engine = StubEngine()
        let cmd = CommandID()
        let intent = submitIntent(store: store, commandID: cmd)
        let staged = try store.stage(intent)
        guard case .staged = staged else { return XCTFail("expected staged") }

        // The app sends admit over the channel with only the commandID.
        let session = Session(version: .v1_0, storeEpoch: store.epochValue, bootID: BootID())
        let envelope = try ControlChannel.encode(request: .admit(session: session, commandID: cmd))
        let (_, decoded) = try ControlChannel.decodeRequest(from: envelope)
        guard case let .admit(_, dcmd) = decoded else { return XCTFail("expected admit") }

        // Node owner resolves from the shared store's ledger, checks capability,
        // and admits. StubEngine fails closed, so expect a committed rejection.
        guard let resolved = try store.intent(for: dcmd) else {
            return XCTFail("staged intent must resolve from the shared store")
        }
        let gate = engine.canExecute(resolved)
        let record = try store.admit(commandID: dcmd) { intent in
            if let gate { return .reject(gate) }
            return .accept(operationID: OperationID(intent.commandID.raw))
        }
        XCTAssertEqual(record.disposition, .rejected, "stub engine must fail closed")

        // The reply round-trips.
        let reply = Reply(requestID: RequestID(), storeEpoch: store.epochValue,
                          bootID: nil, result: .success(.admission(record)))
        let replyEnvelope = try ControlChannel.encode(reply: reply)
        let decodedReply = try ControlChannel.decodeReply(from: replyEnvelope)
        guard case .success(let value) = decodedReply.result else { return XCTFail("expected success") }
        guard case .admission(let rec) = value else { return XCTFail("expected admission") }
        XCTAssertEqual(rec.commandID, cmd)
        XCTAssertEqual(rec.disposition, .rejected)
    }

    func testHelloReplyRoundTrip() throws {
        let descriptor = Descriptor(
            version: .v1_0, storeEpoch: StoreEpoch(), bootID: BootID(), storeSchema: 1,
            capabilities: [
                Capability(feature: .durableMessaging, support: .supported, availability: .available, reason: nil),
                Capability(feature: .rnode, support: .experimental, availability: .requiresAppHost, reason: "needs host"),
            ],
            backend: BuildInfo(name: "python-rns", revision: "abc", adapterRevision: "1"),
            runtime: RuntimeSnapshot(bootID: BootID(), phase: .ready, desiredEnabled: true,
                                     actualEnabled: true, enabledIdentities: [IdentityID()],
                                     connectivity: .interfacesAvailable, observedAt: Instant(3_000_000)))
        let reply = Reply(requestID: RequestID(), storeEpoch: nil, bootID: nil,
                          result: .success(.hello(descriptor)))
        let envelope = try ControlChannel.encode(reply: reply)
        let decoded = try ControlChannel.decodeReply(from: envelope)
        guard case .success(let value) = decoded.result, case .hello(let d) = value else {
            return XCTFail("expected hello descriptor")
        }
        XCTAssertEqual(d.backend.name, "python-rns")
        XCTAssertEqual(d.capabilities.count, 2)
        XCTAssertEqual(d.capabilities.first?.feature, .durableMessaging)
        XCTAssertEqual(d.runtime.phase, .ready)
    }

    func testQueryRoundTrip() throws {
        let session = Session(version: .v1_0, storeEpoch: StoreEpoch(), bootID: BootID())
        let id = IdentityID()
        let envelope = try ControlChannel.encode(request: .query(session: session, query: .identity(id)))
        let (_, decoded) = try ControlChannel.decodeRequest(from: envelope)
        guard case let .query(ds, q) = decoded else { return XCTFail("expected query") }
        XCTAssertEqual(ds.storeEpoch.wire, session.storeEpoch.wire)
        guard case .identity(let got) = q else { return XCTFail("expected identity query") }
        XCTAssertEqual(got, id)
    }

    func testNodeStateQueryResultRoundTrip() throws {
        let record = IdentityRecord(
            id: IdentityID(),
            identityHash: IdentityHash(hex: "000102030405060708090a0b0c0d0e0f")!,
            deliveryDestination: DestinationHash(hex: "11111111111111111111111111111111")!,
            profile: IdentityProfile(name: "Test Identity", announceIntervalMs: 300000),
            revision: 7, retired: false, keyAvailable: true,
            desiredEnabled: true, actualEnabled: true)
        let reply = Reply(requestID: RequestID(), storeEpoch: nil, bootID: nil,
                          result: .success(.query(.identity(record))))
        let envelope = try ControlChannel.encode(reply: reply)
        let decoded = try ControlChannel.decodeReply(from: envelope)
        guard case .success(let value) = decoded.result, case .query(let qr) = value,
              case .identity(let got) = qr else {
            return XCTFail("expected identity query result")
        }
        XCTAssertEqual(got.id, record.id)
        XCTAssertEqual(got.profile.name, "Test Identity")
        XCTAssertEqual(got.revision, 7)
        XCTAssertEqual(got.actualEnabled, true)
    }
}
