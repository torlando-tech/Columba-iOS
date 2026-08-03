import XCTest
@testable import ColumbaApp
import RNSAPI

/// Tests for `Contact.init(from: PathEntry)` announce classification — the
/// single backend-independent point where every networkAnnounces entry gets
/// its `badgeType` / `isRelay`. The Network tab's aspect filter keys on these:
/// `.peers` shows `badgeType == .peer`, `.relays` shows `badgeType == .relay`.
///
/// Contract: the aspect string is the SOLE relay signal, exactly like the
/// reference clients — Sideband types announces by which RNS aspect handler
/// received them, and Android via NodeType.fromAspect. A propagation node is
/// `aspect == "lxmf.propagation"` (surfaced as `entry.isLXMFPropagationNode`);
/// every other aspect is NOT a relay, and unknown is not silently typed as peer.
///
/// Regression target: the "Peers" filter (the default) also showed relays.
/// The old `PropagationNodeInfo.parse(appData)` heuristic accepted ANY
/// >=3-element msgpack array without verifying the destination was a
/// propagation node, so a delivery peer (or audio/site announce) carrying such
/// app_data was flagged `isRelay = true` and leaked into Peers. That heuristic
/// has been removed; classification is now driven purely by the aspect.
///
/// app_data is packed with the production `packMsgPack` so the encoding matches
/// what the device decodes off the wire. Lives in Tests/ColumbaAppTests (runs
/// via the Columba.xcodeproj scheme) because `Contact` lives in the ColumbaApp
/// module.
final class AnnounceClassificationTests: XCTestCase {

    private let pnMetaName: UInt64 = 0x01

    // Canonical LXMF delivery app_data: [display_name, stamp_cost] — 2 elements.
    private func deliveryAppData(name: String?) -> Data {
        let nameVal: MessagePackValue = name.map { .binary(Data($0.utf8)) } ?? .nil
        return packMsgPack(.array([nameVal, .nil]))
    }

    // Canonical LXMF propagation-node app_data: 7 elements, name in metadata[6].
    private func propagationAppData(name: String? = nil, nodeState: Bool = true) -> Data {
        var metadata: [MessagePackValue: MessagePackValue] = [:]
        if let name { metadata[.uint(pnMetaName)] = .binary(Data(name.utf8)) }
        return packMsgPack(.array([
            .bool(false),                           // 0: legacy LXMF PN flag
            .uint(1_700_000_000),                   // 1: timebase
            .bool(nodeState),                       // 2: node state (enabled)
            .uint(50_000),                          // 3: per-transfer limit
            .uint(50_000),                          // 4: per-sync limit
            .array([.uint(0), .uint(0), .uint(0)]), // 5: stamp cost
            .map(metadata),                         // 6: metadata (name lives here)
        ]))
    }

    // A non-propagation announce whose app_data is nonetheless a >=3-element
    // msgpack array — the exact shape that used to fool the relay heuristic.
    private func threeElementAppData() -> Data {
        packMsgPack(.array([.binary(Data("Carol".utf8)), .uint(0), .uint(0)]))
    }

    private func entry(
        aspect: String?,
        appData: Data?,
        isPropagation: Bool = false,
        isTelephony: Bool = false
    ) -> PathEntry {
        PathEntry(
            destinationHash: Data([0xde, 0xad, 0xbe, 0xef]),
            displayName: "Test",
            appData: appData,
            detectedAspect: aspect,
            isLXMFPropagationNode: isPropagation,
            isLXSTTelephony: isTelephony,
            isKnownDestination: true
        )
    }

    // MARK: - The leak (regression)

    /// A delivery peer carrying a >=3-element app_data must classify as a peer,
    /// NOT a relay — this is the exact entry that leaked into the Peers filter.
    func testDeliveryPeerWithThreeElementAppDataIsPeerNotRelay() {
        let c = Contact(from: entry(aspect: "lxmf.delivery", appData: threeElementAppData()))
        XCTAssertEqual(c.badgeType, .peer)
        XCTAssertFalse(c.isRelay)
    }

    func testCanonicalDeliveryPeerIsPeer() {
        let c = Contact(from: entry(aspect: "lxmf.delivery", appData: deliveryAppData(name: "Alice")))
        XCTAssertEqual(c.badgeType, .peer)
        XCTAssertFalse(c.isRelay)
    }

    // MARK: - Relays stay relays

    /// A propagation node tagged with the propagation aspect is a relay.
    func testTaggedPropagationNodeIsRelay() {
        let c = Contact(from: entry(
            aspect: "lxmf.propagation",
            appData: propagationAppData(name: "Hub"),
            isPropagation: true
        ))
        XCTAssertEqual(c.badgeType, .relay)
        XCTAssertTrue(c.isRelay)
    }

    func testPropagationAspectWinsWhenLegacyFlagIsFalse() {
        let c = Contact(from: entry(
            aspect: "lxmf.propagation",
            appData: propagationAppData(name: "Hub"),
            isPropagation: false
        ))
        XCTAssertEqual(c.badgeType, .relay)
        XCTAssertTrue(c.isRelay)
    }

    func testDeliveryAspectWinsWhenLegacyPropagationFlagIsTrue() {
        let c = Contact(from: entry(
            aspect: "lxmf.delivery",
            appData: propagationAppData(name: "Not a relay"),
            isPropagation: true
        ))
        XCTAssertEqual(c.badgeType, .peer)
        XCTAssertFalse(c.isRelay)
    }

    func testCopyCarriesExactAspectDuringSavedContactEnrichment() {
        let saved = Contact(
            id: "saved", displayName: "Saved", identityHash: Data(repeating: 1, count: 16),
            identityHashHex: "01", badgeType: .peer, hopCount: 0, signalStrength: 4,
            timestamp: Date(), isOnline: true, isFavorite: true, isPinned: false,
            isRelay: false, aspect: nil
        )

        let enriched = saved.copy(
            badgeType: .audio,
            aspect: .some("lxst.telephony")
        )

        XCTAssertEqual(enriched.destinationAspect, .lxstTelephony)
        XCTAssertEqual(enriched.badgeType, .audio)
    }

    func testSavedConversationIsExplicitlyTypedAsLXMFDelivery() {
        let saved = Contact(from: ConversationRecord(
            hash: Data(repeating: 0x42, count: 16),
            displayName: "Saved peer",
            isFavorite: 1
        ))

        XCTAssertEqual(saved.destinationAspect, .lxmfDelivery)
        XCTAssertEqual(saved.badgeType, .peer)
    }

    func testValidLXMAContactBindsDestinationHashToPublicIdentity() throws {
        let identity = Identity()
        let destinationHash = Destination.hash(
            identity: identity,
            appName: "lxmf",
            aspects: ["delivery"]
        )
        let destinationHex = destinationHash.map { String(format: "%02x", $0) }.joined()
        let publicKeyHex = identity.publicKeys.map { String(format: "%02x", $0) }.joined()
        let uri = "lxma://\(destinationHex):\(publicKeyHex)"

        let parsed = ContactsViewModel.parseLXMA(uri)

        XCTAssertEqual(parsed?.destinationHash, destinationHash)
        XCTAssertEqual(parsed?.publicKey, identity.publicKeys)
    }

    func testLXMAContactRejectsPublicIdentityThatDoesNotOwnDestination() throws {
        let destinationIdentity = Identity()
        let differentIdentity = Identity()
        let destinationHash = Destination.hash(
            identity: destinationIdentity,
            appName: "lxmf",
            aspects: ["delivery"]
        )
        let destinationHex = destinationHash.map { String(format: "%02x", $0) }.joined()
        let publicKeyHex = differentIdentity.publicKeys.map { String(format: "%02x", $0) }.joined()
        let uri = "lxma://\(destinationHex):\(publicKeyHex)"

        XCTAssertNil(ContactsViewModel.parseLXMA(uri))
    }

    func testSharedQRCodeUsesLXMFDeliveryDestinationNotIdentityHash() {
        let info = IdentityInfo(
            identityHash: String(repeating: "11", count: 16),
            publicKeyHex: String(repeating: "22", count: 64),
            destinationHash: String(repeating: "33", count: 16)
        )

        XCTAssertTrue(info.qrCodeString.hasPrefix("lxma://\(String(repeating: "33", count: 16))"))
        XCTAssertFalse(info.qrCodeString.contains(String(repeating: "11", count: 16)))
    }

    /// Aspect is the sole relay signal: an UNTAGGED announce (no aspect) whose
    /// app_data happens to be propagation-shaped is NOT promoted to a relay.
    /// (Both backends guarantee a genuine propagation node arrives tagged
    /// "lxmf.propagation" or is dropped before reaching here, so the removed
    /// app_data heuristic only ever caught false positives.)
    func testUntaggedPropagationShapedAppDataIsUnsupportedNotRelay() {
        let c = Contact(from: entry(aspect: nil, appData: propagationAppData(name: "Hub")))
        XCTAssertEqual(c.badgeType, .unsupported)
        XCTAssertFalse(c.isRelay)
    }

    /// Unknown is intentionally distinct from a proven LXMF delivery peer.
    func testUnknownAspectIsUnsupportedNotRelay() {
        let c = Contact(from: entry(aspect: "some.future.aspect", appData: threeElementAppData()))
        XCTAssertEqual(c.badgeType, .unsupported)
        XCTAssertFalse(c.isRelay)
    }

    // MARK: - Audio / Site no longer mis-flagged as relays

    func testTelephonyWithThreeElementAppDataIsAudioNotRelay() {
        let c = Contact(from: entry(
            aspect: "lxst.telephony",
            appData: threeElementAppData(),
            isTelephony: true
        ))
        XCTAssertEqual(c.badgeType, .audio)
        XCTAssertFalse(c.isRelay)
    }

    func testNomadnetSiteWithThreeElementAppDataIsNodeNotRelay() {
        let c = Contact(from: entry(aspect: "nomadnetwork.node", appData: threeElementAppData()))
        XCTAssertEqual(c.badgeType, .node)
        XCTAssertFalse(c.isRelay)
    }

    func testEmptyDisplayNameFallsBackToHashPrefix() {
        let contact = Contact(
            id: "unnamed-relay",
            displayName: "   ",
            identityHash: Data(repeating: 0xab, count: 16),
            identityHashHex: String(repeating: "ab", count: 16),
            badgeType: .relay,
            hopCount: 1,
            signalStrength: 4,
            timestamp: Date(),
            isOnline: true,
            isFavorite: false,
            isPinned: false,
            isRelay: true,
            aspect: "lxmf.propagation"
        )

        XCTAssertEqual(contact.resolvedDisplayName, "Peer ABABABAB")
    }

    func testSendPathTimeoutExplainsWhatFailed() {
        XCTAssertEqual(
            MessagingViewModel.failureDescription(for: .requestingPath),
            "No active path to this contact was found after waiting 10 seconds."
        )
    }

    func testSendReadinessAndDestinationFailuresAreActionable() {
        XCTAssertEqual(
            MessagingViewModel.failureDescription(for: .notStarted),
            "The messaging network is not ready."
        )
        XCTAssertEqual(
            MessagingViewModel.failureDescription(for: .badHash),
            "The contact has an invalid LXMF destination."
        )
    }

    func testSendBackendReasonIsPreserved() {
        XCTAssertEqual(
            MessagingViewModel.failureDescription(for: .other("No propagation node is configured.")),
            "No propagation node is configured."
        )
    }

    func testQueuedSendHasNoFailureDescription() {
        XCTAssertNil(MessagingViewModel.failureDescription(for: .queued(messageHash: "00")))
    }
}

final class MessageRepositoryAtomicReplacementTests: XCTestCase {
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-atomic-retry-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
    }

    func testRetryReplacementRekeysExactlyOneDurableRow() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x11, count: 16)
        let oldHash = Data(repeating: 0x22, count: 32)
        let canonicalHash = Data(repeating: 0x33, count: 32)

        let failed = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("payload".utf8)
        )
        failed.hash = oldHash
        failed.state = .failed
        failed.method = .opportunistic
        try await repository.saveMessage(failed)

        let sent = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("payload".utf8)
        )
        sent.hash = canonicalHash
        sent.state = .sent
        sent.method = .propagated
        try await repository.replaceMessage(sent, replacing: oldHash)

        let oldRecord = try await repository.getMessageRecord(id: oldHash)
        let storedCanonical = try await repository.getMessageRecord(id: canonicalHash)
        let canonicalRecord = try XCTUnwrap(storedCanonical)
        XCTAssertNil(oldRecord)
        XCTAssertEqual(canonicalRecord.content, Data("payload".utf8))
        XCTAssertEqual(canonicalRecord.state, LXMessageState.sent.rawValue)
        XCTAssertEqual(canonicalRecord.method, LXDeliveryMethod.propagated.rawValue)
    }

    func testMissingRetrySourceDoesNotCreateCanonicalRow() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let canonicalHash = Data(repeating: 0x44, count: 32)
        let message = RNSAPI.LXMessage(
            destinationHash: Data(repeating: 0x55, count: 16),
            sourceIdentity: nil,
            content: Data("payload".utf8)
        )
        message.hash = canonicalHash
        message.state = .sent

        do {
            try await repository.replaceMessage(
                message,
                replacing: Data(repeating: 0x66, count: 32)
            )
            XCTFail("Expected replacement of a missing source row to fail")
        } catch {
            let canonicalRecord = try await repository.getMessageRecord(id: canonicalHash)
            XCTAssertNil(canonicalRecord)
        }
    }

    func testInterruptedRetryIsRecoveredAsUserVisibleFailure() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x61, count: 16)
        let retryHash = Data(repeating: 0x62, count: 32)
        let retry = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("retry".utf8)
        )
        retry.hash = retryHash
        retry.state = .failed
        try await repository.saveMessage(retry)

        retry.state = .sending
        try await repository.stageRetry(retry, replacing: retryHash)
        let recoveredCount = try await repository.recoverInterruptedRetries()
        XCTAssertEqual(recoveredCount, 1)

        let storedRecovered = try await repository.getMessageRecord(id: retryHash)
        let recovered = try XCTUnwrap(storedRecovered)
        XCTAssertEqual(recovered.state, LXMessageState.failed.rawValue)
        XCTAssertEqual(recovered.receivingInterface, MessageRepository.uncertainRetryMarker)
        let secondRecoveryCount = try await repository.recoverInterruptedRetries()
        XCTAssertEqual(secondRecoveryCount, 0)
    }

    func testNonAppSendingRowIsNotRecovered() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x71, count: 16)
        let retryHash = Data(repeating: 0x72, count: 32)
        let retry = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("active".utf8)
        )
        retry.hash = retryHash
        retry.state = .failed
        try await repository.saveMessage(retry)

        retry.state = .sending
        try await repository.replaceMessage(retry, replacing: retryHash)
        let recoveredCount = try await repository.recoverInterruptedRetries()
        XCTAssertEqual(recoveredCount, 0)

        let stored = try await repository.getMessageRecord(id: retryHash)
        let untouched = try XCTUnwrap(stored)
        XCTAssertEqual(untouched.state, LXMessageState.sending.rawValue)
        XCTAssertNil(untouched.receivingInterface)
    }
}
