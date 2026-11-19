//
//  NodeInboundReplayDiagTests.swift
//  ColumbaAppTests
//
//  The durable node host persists inbound directly into GRDB, so the legacy
//  in-process `[RNS] inbound` diag line (AppServices' `.inbound` event case)
//  never fires; `NodeInboundReplay`'s drain is where the app observes each new
//  inbound message. These tests pin that the replay echoes LIVE arrivals to
//  diag.log in the legacy NO-PII format (the interop suite correlates on
//  `source=<8hex>` + `len=<utf8 bytes>`) and stays silent for historical
//  catch-up rows so a first-run replay cannot reflood the log.
//

import XCTest
@testable import ColumbaApp
import RNSAPI

@available(iOS 17.0, *)
@MainActor
final class NodeInboundReplayDiagTests: XCTestCase {

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-replay-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("lxmf-swift.db")
    }

    private func diagContents() -> String {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let text = try? String(contentsOf: docs.appendingPathComponent("diag.log"), encoding: .utf8)
        else { return "" }
        return text
    }

    private func makeInbound(source: Data, body: String, age: TimeInterval) -> RNSAPI.LXMessage {
        let message = RNSAPI.LXMessage(
            destinationHash: Data(repeating: 0xEE, count: 16),
            sourceIdentity: nil,
            content: Data(body.utf8)
        )
        message.incoming = true
        message.sourceHash = source
        message.hash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        message.timestamp = Date().timeIntervalSince1970 - age
        return message
    }

    private static func hexPrefix8(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    func testLiveInboundIsEchoedToDiagLog() async throws {
        let repository = try MessageRepository(grdbPath: temporaryDatabaseURL().path)
        let handler = IncomingMessageHandler(messageRepository: repository)
        let source = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        try await repository.ensureConversation(source, displayName: nil)
        let body = "diag-live-body"
        try await repository.saveMessage(makeInbound(source: source, body: body, age: 1))

        let replay = NodeInboundReplay(
            repository: repository,
            handler: handler,
            identityScope: "diag-test-\(UUID().uuidString)"
        )
        await replay.catchUp()

        let contents = diagContents()
        let line = "[RNS] inbound source=\(Self.hexPrefix8(source))"
        XCTAssertTrue(contents.contains(line), "expected \(line) in diag.log after replaying a live inbound")
        XCTAssertTrue(contents.contains("len=\(body.count) "), "expected the content byte count in the diag line")
    }

    func testHistoricalCatchUpRowsAreNotEchoed() async throws {
        let repository = try MessageRepository(grdbPath: temporaryDatabaseURL().path)
        let handler = IncomingMessageHandler(messageRepository: repository)
        let source = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        try await repository.ensureConversation(source, displayName: nil)
        // An hour old: a catch-up row delivered before the app last ran, not a
        // live arrival. The replay must still process it, but not log it.
        try await repository.saveMessage(makeInbound(source: source, body: "diag-old-body", age: 3600))

        let replay = NodeInboundReplay(
            repository: repository,
            handler: handler,
            identityScope: "diag-test-\(UUID().uuidString)"
        )
        await replay.catchUp()

        XCTAssertFalse(
            diagContents().contains("[RNS] inbound source=\(Self.hexPrefix8(source))"),
            "catch-up replay of historical rows must not reflood diag.log"
        )
    }
}
