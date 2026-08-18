import XCTest
@testable import ColumbaApp
import RNSAPI
import GRDB
import LXMFSwift

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
@MainActor
final class AnnounceFeedbackStateTests: XCTestCase {
    func testNewestSuccessOwnsVisibilityUntilItsOwnTimeout() async throws {
        let feedback = AnnounceFeedbackState()

        let firstGeneration = feedback.show(for: .seconds(60))
        let secondGeneration = feedback.show(for: .seconds(60))

        feedback.dismiss(ifCurrent: firstGeneration)
        XCTAssertTrue(feedback.isVisible, "A stale timeout must not hide newer feedback")

        feedback.dismiss(ifCurrent: secondGeneration)
        XCTAssertFalse(feedback.isVisible)
    }

    func testStartingAnotherAttemptClearsPriorSuccessAndInvalidatesItsTimeout() {
        let feedback = AnnounceFeedbackState()

        let priorGeneration = feedback.show(for: .seconds(60))
        feedback.hide()

        XCTAssertFalse(feedback.isVisible, "A retry must clear stale success immediately")

        let retryGeneration = feedback.show(for: .seconds(60))
        feedback.dismiss(ifCurrent: priorGeneration)
        XCTAssertTrue(feedback.isVisible, "The prior timeout must not hide retry success")

        feedback.dismiss(ifCurrent: retryGeneration)
        XCTAssertFalse(feedback.isVisible)
    }

    func testSuccessAutomaticallyDismissesAfterRequestedDuration() async throws {
        let feedback = AnnounceFeedbackState()

        feedback.show(for: .milliseconds(20))
        XCTAssertTrue(feedback.isVisible)

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(feedback.isVisible)
    }
}

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
        let routed = ContactsViewModel.parseLXMA("lxma:\(destinationHex):\(publicKeyHex)")

        XCTAssertEqual(parsed?.destinationHash, destinationHash)
        XCTAssertEqual(parsed?.publicKey, identity.publicKeys)
        XCTAssertEqual(routed?.destinationHash, destinationHash)
        XCTAssertEqual(routed?.publicKey, identity.publicKeys)
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

    func testManualContactInputAcceptsTrimmedUppercaseDestinationHash() {
        let hash = Data((0..<16).map(UInt8.init))
        let uppercaseHex = hash.map { String(format: "%02X", $0) }.joined()

        let parsed = ContactsViewModel.parseContactInput("  \n\(uppercaseHex)\t ")

        XCTAssertEqual(parsed?.destinationHash, hash)
        XCTAssertNil(parsed?.publicKey)
    }

    func testManualContactInputAcceptsCryptographicallyBoundLXMAIdentity() throws {
        let identity = Identity()
        let destinationHash = Destination.hash(
            identity: identity,
            appName: "lxmf",
            aspects: ["delivery"]
        )
        let destinationHex = destinationHash.map { String(format: "%02x", $0) }.joined()
        let publicKeyHex = identity.publicKeys.map { String(format: "%02x", $0) }.joined()

        let parsed = ContactsViewModel.parseContactInput("lxma://\(destinationHex):\(publicKeyHex)")

        XCTAssertEqual(parsed?.destinationHash, destinationHash)
        XCTAssertEqual(parsed?.publicKey, identity.publicKeys)
    }

    func testManualContactInputRejectsMalformedDestinationHashes() {
        XCTAssertNil(ContactsViewModel.parseContactInput(String(repeating: "a", count: 31)))
        XCTAssertNil(ContactsViewModel.parseContactInput(String(repeating: "g", count: 32)))
        XCTAssertNil(ContactsViewModel.parseContactInput(String(repeating: "a", count: 34)))
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

@MainActor
final class TruthfulPropagationLifecycleTests: XCTestCase {
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-truthful-propagation-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(atPath: url.path + "-wal")
        try? fm.removeItem(atPath: url.path + "-shm")
    }

    func testQueuedSendRemainsPendingUntilLifecycleCallback() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x41, count: 16)
        let canonicalHash = Data(repeating: 0x42, count: 32)
        let viewModel = MessagingViewModel(
            conversationHash: destination,
            repository: repository,
            appServices: AppServices(),
            identity: Identity(),
            outboundSendOperation: { _ in
                .queued(messageHash: canonicalHash.map { String(format: "%02x", $0) }.joined())
            }
        )

        let accepted = await viewModel.sendMessage(text: "queued only")
        XCTAssertTrue(accepted)

        let visible = try XCTUnwrap(viewModel.messages.last)
        XCTAssertEqual(visible.deliveryStatus, .sending)
        let storedRecord = try await repository.getMessageRecord(id: canonicalHash)
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertEqual(stored.state, LXMessageState.sending.rawValue)
    }

    func testExplicitRelayClearDisablesAutomaticReselection() async {
        let settings = SettingsRepository()
        let originalAutoSelect = await settings.getAutoSelectRelay()
        let manager = PropagationNodeManager(appServices: AppServices())
        manager.autoSelectEnabled = true
        manager.selectedNodeHash = Data(repeating: 0x61, count: 16)
        manager.selectedNodeDeliveryHash = Data(repeating: 0x62, count: 16)
        manager.selectedNodeName = "test relay"

        await manager.clearSelection()

        let isAutoSelectEnabled = manager.autoSelectEnabled
        let selectedHash = manager.selectedNodeHash
        let selectedDeliveryHash = manager.selectedNodeDeliveryHash
        await settings.setAutoSelectRelay(originalAutoSelect)
        XCTAssertFalse(isAutoSelectEnabled)
        XCTAssertNil(selectedHash)
        XCTAssertNil(selectedDeliveryHash)
    }

    func testDeliveryProofReducerRejectsStaleRetryAndFailureDowngrades() {
        let sending = Int(LXMFSwift.LXMessageState.sending.rawValue)
        let sent = Int(LXMFSwift.LXMessageState.sent.rawValue)
        let delivered = Int(LXMFSwift.LXMessageState.delivered.rawValue)
        let failed = Int(LXMFSwift.LXMessageState.failed.rawValue)

        XCTAssertEqual(MessageRepository.monotonicDeliveryState(existing: sent, incoming: sending), sent)
        XCTAssertEqual(MessageRepository.monotonicDeliveryState(existing: sent, incoming: failed), sent)
        XCTAssertEqual(MessageRepository.monotonicDeliveryState(existing: failed, incoming: sending), failed)
        XCTAssertEqual(MessageRepository.monotonicDeliveryState(existing: failed, incoming: sent), sent)
        XCTAssertEqual(MessageRepository.monotonicDeliveryState(existing: failed, incoming: delivered), delivered)
    }

    func testPropagatedMethodRefinesPendingAndRelayAcceptedStates() {
        XCTAssertEqual(
            MessagingViewModel.deliveryStatus(for: .sending, method: .propagated),
            .retryingPropagated
        )
        XCTAssertEqual(
            MessagingViewModel.deliveryStatus(for: .sent, method: .propagated),
            .propagated
        )
        XCTAssertEqual(
            MessagingViewModel.deliveryStatus(for: .delivered, method: .propagated),
            .delivered
        )

        let pending = LXMessage(
            destinationHash: Data(repeating: 0x51, count: 16),
            sourceIdentity: nil,
            content: Data("pending".utf8),
            desiredMethod: .propagated
        )
        pending.hash = Data(repeating: 0x52, count: 32)
        pending.method = .propagated
        pending.state = .sending
        XCTAssertEqual(Message(from: pending, localHash: Data()).deliveryStatus, .retryingPropagated)

        pending.state = .sent
        XCTAssertEqual(Message(from: pending, localHash: Data()).deliveryStatus, .propagated)
    }
}

final class MessageDetailAliasTests: XCTestCase {
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("columba-detail-alias-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
    }

    @MainActor
    func testPublicSendBuffersProofBeforeAliasAndRefreshesOpenDetail() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x41, count: 16)
        let canonicalHash = Data(repeating: 0x42, count: 32)
        let canonicalID = canonicalHash.map { String(format: "%02x", $0) }.joined()
        var viewModel: MessagingViewModel!
        var selected: Message?

        viewModel = MessagingViewModel(
            conversationHash: destination,
            repository: repository,
            appServices: AppServices(),
            identity: Identity(),
            outboundSendOperation: { _ in
                selected = viewModel.messages.last
                NotificationCenter.default.post(
                    name: Notification.Name("ColumbaPythonDelivery"),
                    object: nil,
                    userInfo: [
                        "messageHash": canonicalHash,
                        "state": "delivered",
                        "persisted": false,
                        "deliveryMethod": "propagated",
                    ]
                )
                for _ in 0..<1_000 {
                    if viewModel.hasPendingDeliveryProof(for: canonicalHash) { break }
                    await Task.yield()
                }
                guard viewModel.hasPendingDeliveryProof(for: canonicalHash) else {
                    throw NSError(domain: "MessageDetailAliasTests", code: 1)
                }
                await viewModel.loadMessages()
                guard viewModel.hasPendingDeliveryProof(for: canonicalHash) else {
                    throw NSError(domain: "MessageDetailAliasTests", code: 2)
                }
                return .queued(messageHash: canonicalID)
            }
        )

        let sent = await viewModel.sendMessage(
            text: "hello",
            imageData: nil,
            imageFormat: nil,
            attachments: nil
        )

        XCTAssertTrue(sent)
        let openSelection = try XCTUnwrap(selected)
        let resolved = viewModel.currentMessage(for: openSelection)
        XCTAssertEqual(resolved.id, canonicalID)
        XCTAssertEqual(resolved.deliveryStatus, .delivered)
        XCTAssertEqual(resolved.deliveryMethod, "propagated")
        let storedRecord = try await repository.getMessageRecord(id: canonicalHash)
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertEqual(stored.state, LXMessageState.delivered.rawValue)
        XCTAssertEqual(stored.method, RNSAPI.LXDeliveryMethod.propagated.rawValue)
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

    private func rawMessageSnapshot(_ queue: DatabaseQueue, id: Data) throws -> [String: String] {
        try queue.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = ?", arguments: [id])
            )
            return Dictionary(uniqueKeysWithValues: row.columnNames.map { name in
                let value: DatabaseValue = row[name]
                return (name, String(reflecting: value))
            })
        }
    }

    func testInboundPropagatedMethodPersistsForMessageDetails() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let source = Data(repeating: 0x31, count: 16)
        let messageHash = Data(repeating: 0x32, count: 32)
        let message = RNSAPI.LXMessage(
            destinationHash: source,
            sourceIdentity: nil,
            content: Data("relay message".utf8),
            desiredMethod: .propagated
        )
        message.sourceHash = source
        message.hash = messageHash
        message.method = .propagated
        message.incoming = true
        message.state = .received

        try await repository.saveMessage(message)

        let storedRecord = try await repository.getMessageRecord(id: messageHash)
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertEqual(stored.method, RNSAPI.LXDeliveryMethod.propagated.rawValue)
        XCTAssertEqual(Message(from: stored, localHash: Data()).deliveryMethod, "propagated")
    }

    func testUnknownInboundMethodDoesNotRenderAsOpportunistic() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let source = Data(repeating: 0x33, count: 16)
        let messageHash = Data(repeating: 0x34, count: 32)
        let message = RNSAPI.LXMessage(
            destinationHash: source,
            sourceIdentity: nil,
            content: Data("unknown method".utf8),
            desiredMethod: .unknown
        )
        message.sourceHash = source
        message.hash = messageHash
        message.method = .unknown
        message.incoming = true
        message.state = .received

        try await repository.saveMessage(message)

        let storedRecord = try await repository.getMessageRecord(id: messageHash)
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertEqual(stored.method, RNSAPI.LXDeliveryMethod.unknown.rawValue)
        XCTAssertNil(Message(from: stored, localHash: Data()).deliveryMethod)
    }

    func testUnknownInboundMethodDoesNotUseCorrectiveUpdate() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let inspectionQueue = try DatabaseQueue(path: databaseURL.path)
        try await inspectionQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_unknown_method_correction
                BEFORE UPDATE OF method ON messages
                WHEN NEW.method = 0
                BEGIN
                    SELECT RAISE(ABORT, 'unknown method must be inserted atomically');
                END
                """)
        }
        let source = Data(repeating: 0x37, count: 16)
        let messageHash = Data(repeating: 0x38, count: 32)
        let message = RNSAPI.LXMessage(
            destinationHash: source,
            sourceIdentity: nil,
            content: Data("atomic unknown".utf8),
            desiredMethod: .unknown
        )
        message.sourceHash = source
        message.hash = messageHash
        message.method = .unknown
        message.incoming = true
        message.state = .received

        try await repository.saveMessage(message)

        let storedRecord = try await repository.getMessageRecord(id: messageHash)
        XCTAssertEqual(
            try XCTUnwrap(storedRecord).method,
            RNSAPI.LXDeliveryMethod.unknown.rawValue
        )
    }

    func testUnknownInboundInsertFailureRollsBackConversation() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let inspectionQueue = try DatabaseQueue(path: databaseURL.path)
        try await inspectionQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_unknown_method_insert
                BEFORE INSERT ON messages
                WHEN NEW.method = 0
                BEGIN
                    SELECT RAISE(ABORT, 'forced unknown insert failure');
                END
                """)
        }
        let source = Data(repeating: 0x39, count: 16)
        let messageHash = Data(repeating: 0x3a, count: 32)
        let message = RNSAPI.LXMessage(
            destinationHash: source,
            sourceIdentity: nil,
            content: Data("rollback unknown".utf8),
            desiredMethod: .unknown
        )
        message.sourceHash = source
        message.hash = messageHash
        message.method = .unknown
        message.incoming = true
        message.state = .received

        do {
            try await repository.saveMessage(message)
            XCTFail("Expected forced insert failure")
        } catch {
            // Expected: the trigger aborts the transaction.
        }

        let storedRecord = try await repository.getMessageRecord(id: messageHash)
        let conversation = try await repository.fetchConversation(source)
        XCTAssertNil(storedRecord)
        XCTAssertNil(conversation)
    }

    func testPaperInboundMethodPersistsForMessageDetails() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let source = Data(repeating: 0x35, count: 16)
        let messageHash = Data(repeating: 0x36, count: 32)
        let message = RNSAPI.LXMessage(
            destinationHash: source,
            sourceIdentity: nil,
            content: Data("paper message".utf8),
            desiredMethod: .paper
        )
        message.sourceHash = source
        message.hash = messageHash
        message.method = .paper
        message.incoming = true
        message.state = .received

        try await repository.saveMessage(message)

        let storedRecord = try await repository.getMessageRecord(id: messageHash)
        let stored = try XCTUnwrap(storedRecord)
        XCTAssertEqual(stored.method, RNSAPI.LXDeliveryMethod.paper.rawValue)
        XCTAssertEqual(Message(from: stored, localHash: Data()).deliveryMethod, "paper")
    }

    func testAnnouncedNameAtomicallyReplacesGeneratedFallback() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data([0x05, 0xc5, 0x7e, 0x42] + Array(repeating: 0xaa, count: 12))

        try await repository.ensureConversation(destination, displayName: "Peer 05c57e42")
        let applied = try await repository.applyAnnouncedDisplayName(
            destination,
            displayName: "Hermes Homelab"
        )

        let storedConversation = try await repository.fetchConversation(destination)
        let conversation = try XCTUnwrap(storedConversation)
        XCTAssertTrue(applied)
        XCTAssertEqual(conversation.displayName, "Hermes Homelab")
    }

    func testCachedAnnouncedNameAtomicallyFillsNewContactConversation() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data([0x42, 0x42, 0x42, 0x42] + Array(repeating: 0xbb, count: 12))

        try await repository.ensureConversation(destination, displayName: nil)
        let applied = try await repository.applyAnnouncedDisplayName(
            destination,
            displayName: "Announced Peer"
        )
        try await repository.setFavorite(destination, isFavorite: true)

        let storedConversations = try await repository.fetchConversations(for: [destination])
        let stored = try XCTUnwrap(storedConversations.first)
        XCTAssertTrue(applied)
        XCTAssertEqual(stored.displayName, "Announced Peer")
        XCTAssertEqual(stored.isFavorite, 1)
    }

    func testAnnouncedNameCompareAndSetPreservesCurrentCustomName() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data([0x05, 0xc5, 0x7e, 0x42] + Array(repeating: 0xaa, count: 12))

        try await repository.ensureConversation(destination, displayName: "Peer 05c57e42")
        try await repository.updateDisplayName(destination, displayName: "My Server")
        let applied = try await repository.applyAnnouncedDisplayName(
            destination,
            displayName: "Hermes Homelab"
        )

        let storedConversation = try await repository.fetchConversation(destination)
        let conversation = try XCTUnwrap(storedConversation)
        XCTAssertFalse(applied)
        XCTAssertEqual(conversation.displayName, "My Server")
    }

    func testRetryReplacementRekeysExactlyOneDurableRow() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let queue = try DatabaseQueue(path: databaseURL.path)
        let destination = Data(repeating: 0x11, count: 16)
        let oldHash = Data(repeating: 0x22, count: 32)
        let canonicalHash = Data(repeating: 0x33, count: 32)

        let failed = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("payload".utf8),
            title: Data("title".utf8),
            fields: [
                RNSAPI.LXMessage.FIELD_IMAGE: ["png", Data([0x01, 0x02])] as [Any],
                RNSAPI.LXMessage.FIELD_FILE_ATTACHMENTS: [
                    ["notes.txt", Data("attachment".utf8)] as [Any]
                ] as [Any],
                RNSAPI.LXMessage.FIELD_APP_DATA: ["reply_to": "parent-hash"],
            ]
        )
        failed.hash = oldHash
        failed.state = .failed
        failed.method = .opportunistic
        try await repository.saveMessage(failed)
        try await repository.updateReplyToId(oldHash, replyToId: "parent-hash")
        let originalStored = try await repository.getMessageRecord(id: oldHash)
        let original = try XCTUnwrap(originalStored)
        let originalRaw = try rawMessageSnapshot(queue, id: oldHash)

        failed.state = .sending
        try await repository.stageRetry(failed, replacing: oldHash)

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
        let canonicalRaw = try rawMessageSnapshot(queue, id: canonicalHash)
        XCTAssertNil(oldRecord)
        XCTAssertEqual(canonicalRecord.content, Data("payload".utf8))
        XCTAssertEqual(canonicalRaw["title"], originalRaw["title"])
        XCTAssertEqual(canonicalRecord.packedLxmf, original.packedLxmf)
        XCTAssertEqual(canonicalRecord.replyToId, "parent-hash")
        XCTAssertEqual(canonicalRecord.state, LXMessageState.sent.rawValue)
        XCTAssertEqual(canonicalRecord.method, LXDeliveryMethod.propagated.rawValue)
        XCTAssertEqual(canonicalRecord.timestamp, sent.timestamp)
        XCTAssertNil(canonicalRecord.receivingInterface)
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

    func testReplacementRollsBackAfterPostUpdateFailure() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let queue = try DatabaseQueue(path: databaseURL.path)
        let destination = Data(repeating: 0x81, count: 16)
        let oldHash = Data(repeating: 0x82, count: 32)
        let canonicalHash = Data(repeating: 0x83, count: 32)
        let failed = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("rollback-payload".utf8),
            title: Data("rollback-title".utf8),
            fields: [
                RNSAPI.LXMessage.FIELD_FILE_ATTACHMENTS: [
                    ["rollback.bin", Data([0xaa, 0xbb, 0xcc])] as [Any]
                ] as [Any]
            ]
        )
        failed.hash = oldHash
        failed.state = .failed
        failed.method = .opportunistic
        try await repository.saveMessage(failed)
        try await repository.updateReplyToId(oldHash, replyToId: "rollback-parent")
        let before = try rawMessageSnapshot(queue, id: oldHash)

        try await queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER force_conversation_update_failure
                BEFORE UPDATE ON conversations
                BEGIN
                    SELECT RAISE(ABORT, 'forced post-message-update failure');
                END
                """)
        }

        let sent = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("ignored-new-content".utf8)
        )
        sent.hash = canonicalHash
        sent.state = .sent
        sent.method = .propagated
        do {
            try await repository.replaceMessage(sent, replacing: oldHash)
            XCTFail("Expected the conversation trigger to abort replacement")
        } catch {
            let after = try rawMessageSnapshot(queue, id: oldHash)
            XCTAssertEqual(after, before)
            let canonical = try await repository.getMessageRecord(id: canonicalHash)
            XCTAssertNil(canonical)
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
        do {
            try await repository.stageRetry(retry, replacing: retryHash)
            XCTFail("Expected a second retry owner to lose the compare-and-set")
        } catch {
            // Expected: the first stage changed the durable source state.
        }
        let uncertainBeforeRecovery = try await repository.hasUncertainRetry(for: destination)
        XCTAssertFalse(uncertainBeforeRecovery)
        let recoveredCount = try await repository.recoverInterruptedRetries()
        XCTAssertEqual(recoveredCount, 1)

        let storedRecovered = try await repository.getMessageRecord(id: retryHash)
        let recovered = try XCTUnwrap(storedRecovered)
        XCTAssertEqual(recovered.state, LXMessageState.failed.rawValue)
        XCTAssertEqual(recovered.receivingInterface, MessageRepository.uncertainRetryMarker)
        let uncertainAfterRecovery = try await repository.hasUncertainRetry(for: destination)
        XCTAssertTrue(uncertainAfterRecovery)
        let secondRecoveryCount = try await repository.recoverInterruptedRetries()
        XCTAssertEqual(secondRecoveryCount, 0)
    }

    func testRecoveredCanonicalRetryKeepsStorageIdentityForRetryAndDelete() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x73, count: 16)
        let storageHash = Data(repeating: 0x74, count: 32)
        let canonicalHash = Data(repeating: 0x75, count: 32)
        let retry = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("uncertain retry".utf8)
        )
        retry.hash = storageHash
        retry.state = .failed
        try await repository.saveMessage(retry)

        retry.state = .sending
        try await repository.stageRetry(retry, replacing: storageHash)
        try await repository.recoverStagedRetry(storageHash, canonicalHash: canonicalHash)

        let storedRecovered = try await repository.getMessageRecord(id: storageHash)
        let recoveredRecord = try XCTUnwrap(storedRecovered)
        let visible = Message(from: recoveredRecord, localHash: Data())
        XCTAssertEqual(visible.storageHash, storageHash)
        XCTAssertEqual(visible.messageHash, canonicalHash)
        XCTAssertFalse(visible.isTargetSafe)
        XCTAssertEqual(
            MessageRepository.canonicalHashFromUncertainRetryMarker(recoveredRecord.receivingInterface),
            canonicalHash
        )
        let hasCanonicalUncertainRetry = try await repository.hasUncertainRetry(for: destination)
        XCTAssertTrue(hasCanonicalUncertainRetry)

        retry.state = .sending
        try await repository.stageRetry(retry, replacing: storageHash)
        try await repository.recoverStagedRetry(storageHash, canonicalHash: canonicalHash)
        try await repository.deleteMessage(storageHash)
        let deleted = try await repository.getMessageRecord(id: storageHash)
        XCTAssertNil(deleted)
    }

    func testDeliveryProofRekeysCanonicalUncertainRetryWithoutOpenViewModel() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x76, count: 16)
        let storageHash = Data(repeating: 0x77, count: 32)
        let canonicalHash = Data(repeating: 0x78, count: 32)
        let retry = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("late proof".utf8)
        )
        retry.hash = storageHash
        retry.state = .failed
        try await repository.saveMessage(retry)
        retry.state = .sending
        try await repository.stageRetry(retry, replacing: storageHash)
        try await repository.recoverStagedRetry(storageHash, canonicalHash: canonicalHash)

        let applied = try await repository.applyDeliveryProof(
            canonicalHash: canonicalHash,
            state: .delivered,
            method: .propagated
        )

        XCTAssertTrue(applied)
        let oldRecord = try await repository.getMessageRecord(id: storageHash)
        XCTAssertNil(oldRecord)
        let storedDelivered = try await repository.getMessageRecord(id: canonicalHash)
        let delivered = try XCTUnwrap(storedDelivered)
        XCTAssertEqual(delivered.state, LXMessageState.delivered.rawValue)
        XCTAssertEqual(delivered.method, RNSAPI.LXDeliveryMethod.propagated.rawValue)
        XCTAssertEqual(Message(from: delivered, localHash: Data()).deliveryMethod, "propagated")
        XCTAssertNil(delivered.receivingInterface)

        let staleSentApplied = try await repository.applyDeliveryProof(
            canonicalHash: canonicalHash,
            state: .sent,
            method: .opportunistic
        )
        XCTAssertTrue(staleSentApplied)
        let staleSentRecord = try await repository.getMessageRecord(id: canonicalHash)
        let afterStaleSent = try XCTUnwrap(staleSentRecord)
        XCTAssertEqual(afterStaleSent.state, LXMessageState.delivered.rawValue)
        XCTAssertEqual(afterStaleSent.method, RNSAPI.LXDeliveryMethod.propagated.rawValue)

        let stillHasUncertainRetry = try await repository.hasUncertainRetry(for: destination)
        XCTAssertFalse(stillHasUncertainRetry)
    }

    func testDeliveryProofRemovesCanonicalCollisionAliasAndWarning() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x7c, count: 16)
        let storageHash = Data(repeating: 0x7d, count: 32)
        let canonicalHash = Data(repeating: 0x7e, count: 32)

        let alias = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("uncertain alias".utf8)
        )
        alias.hash = storageHash
        alias.state = .failed
        alias.receivingInterface = MessageRepository.uncertainRetryMarker(
            canonicalHash: canonicalHash
        )
        try await repository.saveMessage(alias)

        let canonical = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("canonical row".utf8)
        )
        canonical.hash = canonicalHash
        canonical.state = .sent
        try await repository.saveMessage(canonical)

        let applied = try await repository.applyDeliveryProof(
            canonicalHash: canonicalHash,
            state: .delivered
        )

        XCTAssertTrue(applied)
        let staleAlias = try await repository.getMessageRecord(id: storageHash)
        XCTAssertNil(staleAlias)
        let storedCanonical = try await repository.getMessageRecord(id: canonicalHash)
        XCTAssertEqual(storedCanonical?.state, LXMessageState.delivered.rawValue)
        let hasWarning = try await repository.hasUncertainRetry(for: destination)
        XCTAssertFalse(hasWarning)
    }

    func testReloadedOptimisticFailureIsNotTargetSafeAndCanBeStaged() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let repository = try MessageRepository(grdbPath: databaseURL.path)
        let destination = Data(repeating: 0x79, count: 16)
        let oldHash = Data(repeating: 0x7a, count: 32)
        let optimisticHash = Data(repeating: 0x7b, count: 32)
        let failed = RNSAPI.LXMessage(
            destinationHash: destination,
            sourceIdentity: nil,
            content: Data("never accepted".utf8)
        )
        failed.hash = oldHash
        failed.state = .failed
        try await repository.saveMessage(failed)

        failed.hash = optimisticHash
        failed.receivingInterface = MessageRepository.optimisticOutboundMarker
        try await repository.replaceMessage(failed, replacing: oldHash)

        let storedRecord = try await repository.getMessageRecord(id: optimisticHash)
        let record = try XCTUnwrap(storedRecord)
        let visible = Message(from: record, localHash: Data())
        XCTAssertFalse(visible.isTargetSafe)

        failed.state = .sending
        try await repository.stageRetry(failed, replacing: optimisticHash)
        let stagedRecord = try await repository.getMessageRecord(id: optimisticHash)
        XCTAssertEqual(stagedRecord?.state, LXMessageState.sending.rawValue)
        XCTAssertEqual(stagedRecord?.receivingInterface, MessageRepository.stagedRetryMarker)
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
        let hasUncertainRetry = try await repository.hasUncertainRetry(for: destination)
        XCTAssertFalse(hasUncertainRetry)

        let stored = try await repository.getMessageRecord(id: retryHash)
        let untouched = try XCTUnwrap(stored)
        XCTAssertEqual(untouched.state, LXMessageState.sending.rawValue)
        XCTAssertNil(untouched.receivingInterface)
    }
}
