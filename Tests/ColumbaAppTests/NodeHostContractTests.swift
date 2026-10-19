import XCTest
import RNSAPI
@testable import ColumbaApp

final class NodeHostContractTests: XCTestCase {
    func testFacadeCarriesFallbackThroughLiveSend() async throws {
        let backend = ProxyRnsBackend { wire in
            guard let request = try? ProxyIPC.decodeRequest(wire) else { return nil }
            switch request {
            case .resolvePath:
                return ProxyIPC.encodeResponse(.ok(Data("{\"ok\":true}".utf8)))
            case .lxmfSend(_, _, _, _, _, let fallback):
                XCTAssertEqual(fallback, "propagated")
                return ProxyIPC.encodeResponse(.ok(try? JSONEncoder().encode(ProxySendOutcome(kind: .queued, detail: "hash"))))
            default:
                return ProxyIPC.encodeResponse(.unsupported)
            }
        }
        let outcome = try await backend.sendLxmfMessage(destHashHex: "abc", content: "body", method: .direct,
            failureFallbackMethod: .propagated, imageData: nil, imageFormat: nil, fileAttachments: nil,
            audioAttachment: nil, iconAppearance: nil, replyToMessageHashHex: nil,
            replyQuotedContent: nil, extraFields: nil)
        XCTAssertEqual(outcome, .queued(messageHash: "hash"))
    }

    func testLocalAdapterPreservesTheCommandEnvelope() async throws {
        let adapter = LocalNodeAdapter(selectedHost: { .foreground }, prepare: {}, cleanup: {}) { request in
            guard case .setPropagationNode(let hash, let cost) = request else { return .error("wrong command") }
            return .ok(Data("\(hash):\(cost)".utf8))
        }
        let reply = await adapter.send(try ProxyIPC.encodeRequest(.setPropagationNode(destHashHex: "relay", stampCost: 16)))
        guard case .ok(let payload) = ProxyIPC.decodeResponse(reply) else { return XCTFail("wrong response") }
        XCTAssertEqual(payload, Data("relay:16".utf8))
    }

    func testLocalStopRemainsAvailableAfterHostPreferenceChanges() async throws {
        let adapter = LocalNodeAdapter(selectedHost: { .networkExtension }, prepare: {}, cleanup: {}) { request in
            guard case .stop = request else { return .error("wrong command") }
            return .ok(nil)
        }
        let reply = await adapter.send(try ProxyIPC.encodeRequest(.stop))
        guard case .ok = ProxyIPC.decodeResponse(reply) else { return XCTFail("old host could not stop") }
    }

    func testLocalAdapterActivatesObserversOnlyAfterSuccessfulStart() async throws {
        let started = expectation(description: "host observers activated")
        let stopped = expectation(description: "host observers stopped")
        let adapter = LocalNodeAdapter(selectedHost: { .foreground }, prepare: {},
            activate: { started.fulfill() }, cleanup: { stopped.fulfill() }) { _ in .ok(nil) }
        _ = await adapter.send(try ProxyIPC.encodeRequest(.start(displayName: "node")))
        _ = await adapter.send(try ProxyIPC.encodeRequest(.stop))
        await fulfillment(of: [started, stopped], timeout: 1)
    }

    func testLocalAdapterKeepsObserversInactiveOnFailedStartAndRetainsThemOnFailedStop() async throws {
        let adapter = LocalNodeAdapter(selectedHost: { .foreground }, prepare: {},
            activate: { XCTFail("failed start activated host observers") },
            cleanup: { XCTFail("failed stop removed host observers") }) { _ in .error("failed") }
        _ = await adapter.send(try ProxyIPC.encodeRequest(.start(displayName: "node")))
        _ = await adapter.send(try ProxyIPC.encodeRequest(.stop))
    }

    func testLocalStartRejectsTheUnselectedHost() async throws {
        let adapter = LocalNodeAdapter(selectedHost: { .networkExtension }, prepare: {}, cleanup: {}) { _ in
            XCTFail("unselected host dispatched a command")
            return .ok(nil)
        }
        let reply = await adapter.send(try ProxyIPC.encodeRequest(.start(displayName: "node")))
        guard case .error = ProxyIPC.decodeResponse(reply) else { return XCTFail("unselected host started") }
    }

    func testProcessLeasePreventsSecondOwnerUntilRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owner.lock")
        let first = NodeProcessLease()
        let second = NodeProcessLease()
        XCTAssertTrue(first.acquire(at: url))
        XCTAssertTrue(first.acquire(at: url), "acquisition by the current owner is idempotent")
        XCTAssertFalse(second.acquire(at: url))
        first.release()
        XCTAssertTrue(second.acquire(at: url))
        XCTAssertFalse(first.acquire(at: url))
        second.release()
        XCTAssertTrue(first.acquire(at: url))
    }

    func testLeaseReleaseForBackgroundDropsLockAndRefusesReacquisitionUntilResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owner.lock")
        let owner = NodeProcessLease()
        let other = NodeProcessLease()
        XCTAssertTrue(owner.acquire(at: url))
        owner.releaseForBackground()
        XCTAssertTrue(other.acquire(at: url), "background release must actually drop the flock")
        XCTAssertFalse(owner.acquire(at: url), "a suspended process must not re-take the lease")
        // A live node reclaims the lease once it is free again.
        other.release()
        XCTAssertTrue(owner.resumeFromBackground(reacquireAt: url))
        XCTAssertFalse(other.acquire(at: url), "re-acquired lease must exclude other owners")
        owner.release()
    }

    func testLeaseResumeWithoutLiveNodeClearsRefusalAndContendedReacquireStaysRetryable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owner.lock")
        let owner = NodeProcessLease()
        let other = NodeProcessLease()
        owner.releaseForBackground()
        XCTAssertTrue(owner.resumeFromBackground(reacquireAt: nil), "no live node: resume only clears the refusal flag")
        XCTAssertTrue(owner.acquire(at: url), "acquire works again after resume")
        owner.releaseForBackground()
        XCTAssertTrue(other.acquire(at: url))
        XCTAssertFalse(owner.resumeFromBackground(reacquireAt: url), "reacquire must fail while another process holds the lease")
        other.release()
        XCTAssertTrue(owner.acquire(at: url), "a failed reacquire must still clear the refusal flag")
        owner.release()
    }

    func testLeaseSelfRestoresOwnershipHeldAtBackgroundOnResumeWithoutURL() throws {
        // Models the slow-startup ordering: start() acquired the lease, the
        // app backgrounded mid-Python-startup, and foreground returns before
        // isRunning flips - so the caller resumes with nil and cannot know
        // ownership must come back.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owner.lock")
        let owner = NodeProcessLease()
        let other = NodeProcessLease()
        XCTAssertTrue(owner.acquire(at: url))
        owner.releaseForBackground()
        XCTAssertTrue(other.acquire(at: url), "background release must drop the flock")
        other.release()
        XCTAssertTrue(owner.resumeFromBackground(reacquireAt: nil), "resume must restore ownership held at background")
        XCTAssertFalse(other.acquire(at: url), "restored lease must exclude other owners")
        owner.release()
    }

    func testLeaseExplicitReleaseDuringBackgroundWindowSuppressesSelfRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("owner.lock")
        let owner = NodeProcessLease()
        let other = NodeProcessLease()
        XCTAssertTrue(owner.acquire(at: url))
        owner.releaseForBackground()
        owner.release() // stop() completed inside the background-task window
        XCTAssertTrue(owner.resumeFromBackground(reacquireAt: nil))
        XCTAssertTrue(other.acquire(at: url), "an explicit release must never self-restore")
        other.release()
    }

    func testStateMigrationPreservesNewerSharedFilesAndRetriesMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("private")
        let destination = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: source.appendingPathComponent("known_destinations"))
        try Data("new".utf8).write(to: destination.appendingPathComponent("known_destinations"))
        try Data("routes".utf8).write(to: source.appendingPathComponent("path_table"))
        try Data("sqlite".utf8).write(to: source.appendingPathComponent("lxmf-swift.db-wal"))
        try NodeStateMigration.copyMissingState(from: source, to: destination)
        try NodeStateMigration.copyMissingState(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("known_destinations")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("path_table")), Data("routes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("lxmf-swift.db-wal").path))
    }

    func testFallbackSurvivesCommandAndDurableOutboxRoundTrip() throws {
        let request = ProxyRequest.lxmfSend(destHashHex: "abc", content: "body", method: "direct", fieldsData: Data([1, 2]), sendId: "stable", failureFallbackMethod: "propagated")
        let wire = try ProxyIPC.encodeRequest(request)
        guard case .lxmfSend(let hash, let body, let method, let fields, let id, let fallback) = try ProxyIPC.decodeRequest(wire) else {
            return XCTFail("send did not survive framing")
        }
        XCTAssertEqual(hash, "abc")
        XCTAssertEqual(body, "body")
        XCTAssertEqual(method, "direct")
        XCTAssertEqual(fields, Data([1, 2]))
        XCTAssertEqual(id, "stable")
        XCTAssertEqual(fallback, "propagated")
        let entry = OutboxEntry(destHashHex: hash, content: body, method: method, fieldsData: fields, messageHashHex: nil, sendId: id, createdAt: 1, failureFallbackMethod: fallback)
        XCTAssertEqual(try JSONDecoder().decode(OutboxEntry.self, from: JSONEncoder().encode(entry)), entry)
    }
}
