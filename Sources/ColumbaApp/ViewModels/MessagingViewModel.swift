//
//  MessagingViewModel.swift
//  Columba-iOS
//
//  ViewModel for messaging screen using @Observable macro.
//  Provides async message loading and sending via LXMFSwift.
//

import SwiftUI
import RNSAPI
import Observation
import os.log

/// ViewModel for the messaging screen.
///
/// Uses iOS 17+ @Observable macro for automatic SwiftUI observation.
/// Implements optimistic UI pattern - shows message immediately while
/// sending via LXMRouter.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class MessagingViewModel {
    struct OutboundSendRequest {
        let destHashHex: String
        let content: String
        let method: RNSAPI.LXDeliveryMethod
        let failureFallbackMethod: RNSAPI.LXDeliveryMethod?
        let imageData: Data?
        let imageFormat: String?
        let fileAttachments: [RnsFileAttachment]?
        let iconAppearance: IconAppearance?
        let replyToMessageHashHex: String?
        let replyQuotedContent: String?
        let extraFields: [UInt8: Data]?
    }

    typealias OutboundSendOperation = @MainActor (OutboundSendRequest) async throws -> SendOutcome

    struct PendingDeliveryProof: Equatable {
        let state: LXMessageState
        let method: RNSAPI.LXDeliveryMethod?
    }

    // MARK: - Published Properties

    /// List of messages in chronological order (oldest first).
    public var messages: [Message] = []

    /// True while loading messages from database.
    public var isLoading: Bool = false

    /// True while loading older messages (pagination).
    public var isLoadingMore: Bool = false

    /// True when all messages have been loaded (no more pages).
    public var allMessagesLoaded: Bool = false

    /// Error message if operation failed, nil otherwise.
    public var errorMessage: String? = nil

    /// Message being replied to (set by UI when user swipes or taps Reply).
    public var replyToMessage: Message? = nil

    /// Page size for message fetching.
    private static let pageSize = 50
    private var pageCursor = MessagePageCursor()
    private static let interruptedRetryWarning =
        "A message retry was interrupted before delivery confirmation. Verify whether it arrived before retrying."

    // MARK: - Dependencies

    private let conversationHash: Data
    private let repository: MessageRepository
    private let appServices: AppServices
    private let settingsRepository = SettingsRepository()
    private let displayName: String?
    private var identityOverride: Identity?
    private var outboundSendOperation: OutboundSendOperation?
    private let logger = Logger(subsystem: "network.columba.Columba", category: "MessagingViewModel")

    /// Observation token for incoming message notifications.
    private var notificationTask: Any?
    private var deliveryTask: Any?
    private var pendingRefresh = false
    private var paginationGeneration: UInt64 = 0
    private var unpersistedOutboundIDs: Set<String> = []
    private var unsavedFailedOutboundIDs: Set<String> = []
    private var stagedRetryRecoveryHashes: [String: Data] = [:]
    private var pendingOutboundAliases: [String: String] = [:]
    private var canonicalizedOutboundAliases: [String: String] = [:]
    private var pendingDeliveryProofs: [String: PendingDeliveryProof] = [:]

    // MARK: - Initialization

    /// Create ViewModel for a specific conversation.
    ///
    /// - Parameters:
    ///   - conversationHash: Destination hash (16 bytes) of the conversation
    ///   - repository: MessageRepository for database access
    ///   - appServices: AppServices for router and identity access
    ///   - displayName: Optional display name for the peer
    public init(
        conversationHash: Data,
        repository: MessageRepository,
        appServices: AppServices,
        displayName: String? = nil
    ) {
        self.conversationHash = conversationHash
        self.repository = repository
        self.appServices = appServices
        self.displayName = displayName

        // Listen for incoming messages and reload when this conversation is affected
        notificationTask = NotificationCenter.default.addObserver(
            forName: IncomingMessageHandler.messageReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let sourceHash = notification.userInfo?["sourceHash"] as? Data,
               sourceHash != self.conversationHash {
                return
            }
            Task { @MainActor in
                await self.loadMessages()
            }
        }

        // Listen for delivery / failure proofs (double-check indicator). The DB
        // row is already updated by AppServices; we just flip the in-memory
        // bubble in place so the open chat reflects it without a full reload.
        deliveryTask = NotificationCenter.default.addObserver(
            forName: Notification.Name("ColumbaPythonDelivery"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let hashData = notification.userInfo?["messageHash"] as? Data,
                  let state = notification.userInfo?["state"] as? String else { return }
            let proofPersisted = notification.userInfo?["persisted"] as? Bool ?? false
            let deliveryMethod = notification.userInfo?["deliveryMethod"] as? String
            let hashHex = hashData.map { String(format: "%02x", $0) }.joined()
            Task { @MainActor in
                let proofState: LXMessageState
                switch state {
                case "sent": proofState = .sent
                case "delivered": proofState = .delivered
                case "failed": proofState = .failed
                default:
                    self.logger.warning("[MSG_VM] Ignoring unknown delivery state: \(state, privacy: .public)")
                    return
                }
                let proofMethod = Self.deliveryMethod(from: deliveryMethod)
                let wasAliased = self.pendingOutboundAliases[hashHex] != nil
                let visibleID = Self.visibleMessageID(
                    for: hashHex,
                    aliases: self.pendingOutboundAliases
                )
                if !proofPersisted {
                    self.pendingDeliveryProofs[hashHex] = PendingDeliveryProof(
                        state: proofState,
                        method: proofMethod
                    )
                }
                guard let index = self.messages.firstIndex(where: { $0.id == visibleID }) else { return }
                if wasAliased && proofPersisted {
                    self.messages[index] = Self.canonicalizedMessage(
                        self.messages[index],
                        canonicalHash: hashData,
                        proofState: proofState
                    )
                    if let deliveryMethod, !deliveryMethod.isEmpty {
                        self.messages[index].deliveryMethod = deliveryMethod
                    }
                    Self.recordCanonicalAlias(
                        canonicalID: hashHex,
                        pendingAliases: &self.pendingOutboundAliases,
                        canonicalizedAliases: &self.canonicalizedOutboundAliases
                    )
                    self.pendingDeliveryProofs.removeValue(forKey: hashHex)
                    await self.invalidatePaginationAndRefresh()
                } else {
                    self.messages[index].deliveryStatus = Self.deliveryStatus(for: proofState)
                    if let deliveryMethod, !deliveryMethod.isEmpty {
                        self.messages[index].deliveryMethod = deliveryMethod
                    }
                }
            }
        }
    }

    convenience init(
        conversationHash: Data,
        repository: MessageRepository,
        appServices: AppServices,
        identity: Identity,
        outboundSendOperation: @escaping OutboundSendOperation
    ) {
        self.init(
            conversationHash: conversationHash,
            repository: repository,
            appServices: appServices
        )
        self.identityOverride = identity
        self.outboundSendOperation = outboundSendOperation
    }

    deinit {
        if let token = notificationTask {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = deliveryTask {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public Methods

    /// Load the most recent page of messages for this conversation.
    @MainActor
    public func loadMessages() async {
        guard !isLoading, !isLoadingMore else {
            pendingRefresh = true
            return
        }
        isLoading = true
        let loadGeneration = paginationGeneration

        do {
            // Ensure conversation exists, then clear unread state as soon as the
            // user opens it. Message decoding or reply-preview failures must not
            // leave a stale badge behind after the conversation was viewed.
            try await repository.ensureConversation(conversationHash, displayName: displayName)
            try await repository.markConversationRead(conversationHash)
            await synchronizeBadgeWithDurableUnreadCount()
            await retryPendingDeliveryProofs()

            // Preserve the current history depth when repository notifications
            // refresh the newest records. If a burst arrived, expand the fetch
            // until it still contains the prior oldest persisted row; a fixed
            // one-record allowance can evict the visible anchor.
            let retainedRecordCount = pageCursor.nextOffset
            let priorOldestID = messages.first {
                !unpersistedOutboundIDs.contains($0.id)
            }?.id
            var fetchLimit = max(Self.pageSize, retainedRecordCount)

            let hasInterruptedRetry = try await repository.hasUncertainRetry(for: conversationHash)
            var records = try await repository.fetchMessageRecords(
                for: conversationHash, limit: fetchLimit, offset: 0)
            while loadGeneration == paginationGeneration,
                  let priorOldestID,
                  let expandedLimit = MessageRefreshWindowPolicy.expandedLimit(
                    currentLimit: fetchLimit,
                    fetchedCount: records.count,
                    containsPriorOldest: records.contains {
                        Self.recordID($0) == priorOldestID
                    },
                    pageSize: Self.pageSize
                  ) {
                fetchLimit = expandedLimit
                records = try await repository.fetchMessageRecords(
                    for: conversationHash, limit: fetchLimit, offset: 0
                )
            }
            let reachedDatabaseEnd = records.count < fetchLimit
            let retainedCount = MessageRefreshWindowPolicy.retainedPrefixCount(
                recordIDs: records.map(Self.recordID),
                priorOldestID: priorOldestID
            )
            let trimmedToPriorWindow = retainedCount < records.count
            records = Array(records.prefix(retainedCount))
            let loaded = records.reversed()
                .map { Message(from: $0, localHash: appServices.localIdentityHash) }
                .filter { !$0.isEmpty }  // Hide telemetry-only messages (e.g. location sharing)

            // Resolve reply previews from loaded messages
            var resolvedMessages = loaded
            let contentById = Dictionary(loaded.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
            for i in resolvedMessages.indices {
                if let replyId = resolvedMessages[i].replyToId {
                    if let preview = contentById[replyId] {
                        resolvedMessages[i].replyToPreview = String(preview.prefix(80))
                    } else {
                        // DB fallback for messages not in current page
                        resolvedMessages[i].replyToPreview = await resolveReplyPreview(replyId)
                    }
                }
                if !resolvedMessages[i].isTargetSafe,
                   let canonicalHash = resolvedMessages[i].messageHash,
                   canonicalHash != resolvedMessages[i].storageHash {
                    pendingOutboundAliases[Self.hexString(canonicalHash)] = resolvedMessages[i].id
                }
                if let proof = Self.pendingProofDetails(
                    forVisibleID: resolvedMessages[i].id,
                    aliases: pendingOutboundAliases,
                    proofs: pendingDeliveryProofs
                ) {
                    resolvedMessages[i].deliveryStatus = Self.deliveryStatus(for: proof.state)
                    if let method = proof.method {
                        resolvedMessages[i].deliveryMethod = method.rawValue
                    }
                }
            }
            await reconcileAliasedDeliveryProofs(in: resolvedMessages)

            guard loadGeneration == paginationGeneration else {
                pendingRefresh = true
                isLoading = false
                await runPendingRefreshIfNeeded()
                return
            }

            messages = Self.mergingPendingOutbound(
                loaded: resolvedMessages,
                current: messages,
                pendingIDs: unpersistedOutboundIDs
            )
            pageCursor.reset(recordCount: records.count)
            allMessagesLoaded = reachedDatabaseEnd && !trimmedToPriorWindow

            // Reconcile messages that arrived after the initial read reset but
            // were included in the page we just displayed.
            try await repository.markConversationRead(conversationHash)
            await synchronizeBadgeWithDurableUnreadCount()

            errorMessage = hasInterruptedRetry
                ? Self.interruptedRetryWarning
                : nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        await runPendingRefreshIfNeeded()
    }

    @MainActor
    private func synchronizeBadgeWithDurableUnreadCount() async {
        #if os(iOS)
        await NotificationService.shared.synchronizeBadgeWithDurableUnreadCount(
            messageRepository: repository
        )
        #endif
    }

    /// Load older messages when scrolling up.
    @MainActor
    @discardableResult
    public func loadMoreMessages() async -> Bool {
        guard !isLoading, !isLoadingMore, !allMessagesLoaded else { return false }
        isLoadingMore = true
        let loadGeneration = paginationGeneration
        var consumedPage = false

        do {
            // Database pages can contain telemetry-only records that do not
            // become visible bubbles. Offset by fetched records rather than
            // `messages.count` so those hidden records cannot cause overlapping
            // pages and duplicate IDs.
            let offset = pageCursor.nextOffset
            let hasInterruptedRetry = try await repository.hasUncertainRetry(for: conversationHash)
            let records = try await repository.fetchMessageRecords(
                for: conversationHash, limit: Self.pageSize, offset: offset)

            if loadGeneration != paginationGeneration {
                // A new record was persisted at the head while this offset page
                // was in flight. Discard the stale page and rebuild from offset
                // zero so an overlap cannot advance the cursor past a record.
                pendingRefresh = true
            } else {
                consumedPage = true
                if hasInterruptedRetry {
                    errorMessage = Self.interruptedRetryWarning
                } else if errorMessage == Self.interruptedRetryWarning {
                    errorMessage = nil
                }
                if records.isEmpty {
                    allMessagesLoaded = true
                } else {
                    pageCursor.recordFetchedPage(recordCount: records.count)
                    let older = records.reversed()
                        .map { Message(from: $0, localHash: appServices.localIdentityHash) }
                        .filter { !$0.isEmpty }  // Hide telemetry-only messages
                    var knownIDs = Set(messages.map(\.id))
                    let uniqueOlder = older.filter { knownIDs.insert($0.id).inserted }

                    messages.insert(contentsOf: uniqueOlder, at: 0)
                    if records.count < Self.pageSize {
                        allMessagesLoaded = true
                    }
                }
            }
        } catch {
            logger.error("Failed to load more messages: \(error.localizedDescription)")
        }

        isLoadingMore = false
        await runPendingRefreshIfNeeded()
        return consumedPage
    }

    @MainActor
    private func runPendingRefreshIfNeeded() async {
        guard pendingRefresh, !isLoading, !isLoadingMore else { return }
        pendingRefresh = false
        await loadMessages()
    }

    @MainActor
    private func invalidatePaginationAndRefresh() async {
        paginationGeneration &+= 1
        pendingRefresh = true
        await runPendingRefreshIfNeeded()
    }

    @MainActor
    private func recoverStagedRetryAfterPersistenceFailure(
        _ hash: Data?,
        canonicalHash: Data?
    ) async -> Bool {
        guard let hash else { return true }
        do {
            try await repository.recoverStagedRetry(hash, canonicalHash: canonicalHash)
            await invalidatePaginationAndRefresh()
            return true
        } catch {
            logger.error("[MSG_VM] failed to recover staged retry: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func reconcilePendingDeliveryProof(for hash: Data) async {
        let hashHex = Self.hexString(hash)
        Self.recordCanonicalAlias(
            canonicalID: hashHex,
            pendingAliases: &pendingOutboundAliases,
            canonicalizedAliases: &canonicalizedOutboundAliases
        )
        guard let proof = pendingDeliveryProofs[hashHex] else { return }
        do {
            let rowUpdated = try await repository.updateMessageState(
                id: hash,
                state: proof.state,
                method: proof.method
            )
            if rowUpdated, pendingDeliveryProofs[hashHex] == proof {
                pendingDeliveryProofs.removeValue(forKey: hashHex)
            }
        } catch {
            logger.error("[MSG_VM] failed to persist delivery proof: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func retryPendingDeliveryProofs() async {
        for (hashHex, proof) in Array(pendingDeliveryProofs) {
            guard pendingOutboundAliases[hashHex] == nil,
                  let hash = Self.hexToData(hashHex) else { continue }
            do {
                let rowUpdated = try await repository.updateMessageState(
                    id: hash,
                    state: proof.state,
                    method: proof.method
                )
                if rowUpdated, pendingDeliveryProofs[hashHex] == proof {
                    pendingDeliveryProofs.removeValue(forKey: hashHex)
                }
            } catch {
                logger.error("[MSG_VM] delivery proof retry failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func reconcileAliasedDeliveryProofs(in loaded: [Message]) async {
        for message in loaded where !message.isTargetSafe {
            guard let canonicalHash = message.messageHash,
                  let storageHash = message.storageHash,
                  let proof = pendingDeliveryProofs[Self.hexString(canonicalHash)] else { continue }
            do {
                let rowUpdated = try await repository.updateMessageState(
                    id: storageHash,
                    state: proof.state,
                    method: proof.method
                )
                if rowUpdated,
                   pendingDeliveryProofs[Self.hexString(canonicalHash)] == proof {
                    pendingDeliveryProofs.removeValue(forKey: Self.hexString(canonicalHash))
                }
            } catch {
                logger.error("[MSG_VM] aliased delivery proof reconciliation failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func hasPendingDeliveryProof(for hash: Data) -> Bool {
        pendingDeliveryProofs[Self.hexString(hash)] != nil
    }

    private func pendingDeliveryProof(for hash: Data) -> PendingDeliveryProof? {
        let hashHex = Self.hexString(hash)
        return pendingDeliveryProofs[hashHex]
    }

    @MainActor
    private func clearPendingAliases(for visibleID: String) {
        let hashes = pendingOutboundAliases.compactMap { key, value in
            value == visibleID ? key : nil
        }
        for hash in hashes {
            pendingOutboundAliases.removeValue(forKey: hash)
            pendingDeliveryProofs.removeValue(forKey: hash)
        }
        canonicalizedOutboundAliases.removeValue(forKey: visibleID)
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func visibleMessageID(
        for realID: String,
        aliases: [String: String]
    ) -> String {
        aliases[realID] ?? realID
    }

    static func recordCanonicalAlias(
        canonicalID: String,
        pendingAliases: inout [String: String],
        canonicalizedAliases: inout [String: String]
    ) {
        guard let optimisticID = pendingAliases.removeValue(forKey: canonicalID) else { return }
        canonicalizedAliases[optimisticID] = canonicalID
    }

    @MainActor
    func registerPendingOutboundAlias(canonicalHash: Data, optimisticID: String) {
        pendingOutboundAliases[Self.hexString(canonicalHash)] = optimisticID
    }

    private static func deliveryMethod(from value: String?) -> RNSAPI.LXDeliveryMethod? {
        switch value {
        case "opportunistic": return .opportunistic
        case "direct": return .direct
        case "propagated": return .propagated
        default: return nil
        }
    }

    func currentMessage(for selected: Message) -> Message {
        Self.resolveCurrentMessage(
            selected,
            messages: messages,
            pendingAliases: pendingOutboundAliases,
            canonicalizedAliases: canonicalizedOutboundAliases
        )
    }

    static func resolveCurrentMessage(
        _ selected: Message,
        messages: [Message],
        pendingAliases: [String: String],
        canonicalizedAliases: [String: String]
    ) -> Message {
        if let exact = messages.first(where: { $0.id == selected.id }) {
            return exact
        }
        let canonicalID = canonicalizedAliases[selected.id]
            ?? pendingAliases.first(where: { $0.value == selected.id })?.key
        guard let canonicalID else { return selected }
        return messages.first(where: { $0.id == canonicalID }) ?? selected
    }

    private static func pendingProofDetails(
        forVisibleID visibleID: String,
        aliases: [String: String],
        proofs: [String: PendingDeliveryProof]
    ) -> PendingDeliveryProof? {
        if let direct = proofs[visibleID] { return direct }
        guard let canonicalID = aliases.first(where: {
            $0.value == visibleID && proofs[$0.key] != nil
        })?.key else {
            return nil
        }
        return proofs[canonicalID]
    }

    static func pendingProof(
        forVisibleID visibleID: String,
        aliases: [String: String],
        proofs: [String: LXMessageState]
    ) -> LXMessageState? {
        if let direct = proofs[visibleID] { return direct }
        guard let canonicalID = aliases.first(where: {
            $0.value == visibleID && proofs[$0.key] != nil
        })?.key else {
            return nil
        }
        return proofs[canonicalID]
    }

    static func canonicalizedMessage(
        _ message: Message,
        canonicalHash: Data,
        proofState: LXMessageState
    ) -> Message {
        var canonical = Message(
            id: hexString(canonicalHash),
            content: message.content,
            timestamp: message.timestamp,
            isFromMe: message.isFromMe,
            deliveryStatus: deliveryStatus(for: proofState),
            imageData: message.imageData,
            imageFormat: message.imageFormat,
            attachments: message.attachments,
            replyToId: message.replyToId,
            replyToPreview: message.replyToPreview,
            reactions: message.reactions,
            storageHash: canonicalHash,
            isTargetSafe: true
        )
        canonical.messageHash = canonicalHash
        canonical.deliveryMethod = message.deliveryMethod
        canonical.rssi = message.rssi
        canonical.snr = message.snr
        canonical.receivedInterface = nil
        return canonical
    }

    static func deliveryStatus(for state: LXMessageState) -> DeliveryStatus {
        switch state {
        case .sent: return .sent
        case .delivered: return .delivered
        case .failed: return .failed
        default: return .sent
        }
    }

    static func mergingPendingOutbound(
        loaded: [Message],
        current: [Message],
        pendingIDs: Set<String>
    ) -> [Message] {
        let pending = current.filter { pendingIDs.contains($0.id) }
        let pendingMessageIDs = Set(pending.map(\.id))
        let durable = loaded.filter { !pendingMessageIDs.contains($0.id) }
        return (durable + pending)
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp == rhs.element.timestamp {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.timestamp < rhs.element.timestamp
            }
            .map(\.element)
    }

    private static func recordID(_ record: MessageRecord) -> String {
        record.messageId.map { String(format: "%02x", $0) }.joined()
    }

    /// Actionable failure returned when a backend does not accept a send.
    private struct SendFailure: LocalizedError {
        let category: String
        let errorDescription: String?
    }

    static func failureDescription(for outcome: SendOutcome) -> String? {
        switch outcome {
        case .queued:
            return nil
        case .requestingPath:
            return "No active path to this contact was found after waiting 10 seconds."
        case .badHash:
            return "The contact has an invalid LXMF destination."
        case .notStarted:
            return "The messaging network is not ready."
        case .other(let reason):
            return reason.isEmpty ? "The messaging backend rejected the message." : reason
        }
    }

    private static func failureCategory(for outcome: SendOutcome) -> String {
        switch outcome {
        case .queued: return "invalid-message-hash"
        case .requestingPath: return "path-unavailable"
        case .badHash: return "invalid-destination"
        case .notStarted: return "backend-not-started"
        case .other: return "backend-rejected"
        }
    }

    private static func queuedHash(from outcome: SendOutcome) throws -> Data {
        if case .queued(let hashHex) = outcome {
            guard let hash = Data(hexString: hashHex), hash.count == 32 else {
                throw SendFailure(
                    category: "invalid-message-hash",
                    errorDescription: "The network backend accepted the message but returned an invalid message identifier."
                )
            }
            return hash
        }
        throw SendFailure(
            category: failureCategory(for: outcome),
            errorDescription: failureDescription(for: outcome)
        )
    }

    @MainActor
    private func sendOutbound(
        _ request: OutboundSendRequest,
        backend: (any RnsBackend)?
    ) async throws -> SendOutcome {
        if let outboundSendOperation {
            return try await outboundSendOperation(request)
        }
        guard let backend else {
            throw NSError(domain: "MessagingViewModel", code: 1)
        }
        return try await backend.lxmf.sendLxmfMessage(
            destHashHex: request.destHashHex,
            content: request.content,
            method: request.method,
            failureFallbackMethod: request.failureFallbackMethod,
            imageData: request.imageData,
            imageFormat: request.imageFormat,
            fileAttachments: request.fileAttachments,
            iconAppearance: request.iconAppearance,
            replyToMessageHashHex: request.replyToMessageHashHex,
            replyQuotedContent: request.replyQuotedContent,
            extraFields: request.extraFields
        )
    }

    private static func failureCategory(_ error: Error) -> String {
        (error as? SendFailure)?.category ?? "backend-error"
    }

    private func persistMessage(_ message: LXMessage, replacing oldHash: Data?) async throws {
        if let oldHash {
            try await repository.replaceMessage(message, replacing: oldHash)
        } else {
            try await repository.saveMessage(message)
        }
    }

    /// Send a text-only message (convenience wrapper).
    @MainActor
    public func sendMessage(text: String) async -> Bool {
        await sendMessage(text: text, imageData: nil, imageFormat: nil, attachments: nil)
    }

    /// Send a message with optional image, file attachments, and reply reference.
    ///
    /// - Parameters:
    ///   - text: Message text (can be empty if attachments provided)
    ///   - imageData: PNG/JPEG image bytes for FIELD_IMAGE
    ///   - imageFormat: Image format string ("png" or "jpeg")
    ///   - attachments: File attachments as (name, data) tuples for FIELD_FILE_ATTACHMENTS
    ///   - replyToId: Hex hash of message being replied to (optional)
    /// - Returns: True if message was sent successfully
    @MainActor
    public func sendMessage(
        text: String,
        imageData: Data?,
        imageFormat: String?,
        attachments: [(name: String, data: Data)]?,
        replyToId: String? = nil,
        localRetryHash: Data? = nil,
        replacedStorageHash: Data? = nil
    ) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || imageData != nil || (attachments != nil && !attachments!.isEmpty) else {
            return false
        }

        guard let identity = identityOverride ?? appServices.identity else {
            errorMessage = "Identity not initialized"
            return false
        }

        let backend = appServices.backend
        guard backend != nil || outboundSendOperation != nil else {
            errorMessage = "Backend not initialized"
            return false
        }


        // Always start with opportunistic (single encrypted packet, no link needed).
        // For large messages that exceed single-packet size, handleOutbound() will
        // auto-fallback using the fallbackMethod (direct or propagated per settings).
        // On failure, retry-via-relay handles the final propagated fallback.
        let settingsMethod = await settingsRepository.getDefaultDeliveryMethod()
        let fallbackForLargeMessages: LXDeliveryMethod = (settingsMethod == "propagated") ? .propagated : .direct
        let retryViaRelay = await settingsRepository.getRetryViaRelay()

        // Resolve icon once — passed to the typed backend send below and also
        // stashed in the local Compat.LXMessage fields for persistence/display.
        let icon = await settingsRepository.getIconAppearance()
        var fields: [UInt8: Any] = [:]
        if let icon { fields[IconAppearance.fieldKey] = icon.toLXMFFieldValue() }

        // Add image field (FIELD_IMAGE = 0x06): [format_string, binary_data].
        // Both halves are required; warn (don't silently drop) if a caller
        // supplied one without the other — e.g. compression returned nil data,
        // or a deep-link path passed bytes with no format.
        if let imageData, let imageFormat {
            fields[LXMessage.FIELD_IMAGE] = [imageFormat, imageData] as [Any]
        } else if imageData != nil || imageFormat != nil {
            logger.error("FIELD_IMAGE dropped — need both data and format (haveData=\(imageData != nil, privacy: .public) format=\(imageFormat ?? "nil", privacy: .public))")
        }

        // Add file attachments field (FIELD_FILE_ATTACHMENTS = 0x05): [[name, data], ...]
        if let attachments, !attachments.isEmpty {
            fields[LXMessage.FIELD_FILE_ATTACHMENTS] = attachments.map { [$0.name, $0.data] as [Any] } as [Any]
        }

        // Add reply reference (FIELD_APP_DATA = 0x10)
        if let replyToId {
            fields[LXMessage.FIELD_APP_DATA] = ["reply_to": replyToId] as [String: Any]
        }

        // Create outbound LXMF message — always opportunistic first
        let lxMessage = LXMessage(
            destinationHash: conversationHash,
            sourceIdentity: identity,
            content: trimmedText.data(using: .utf8) ?? Data(),
            title: Data(),
            fields: fields.isEmpty ? nil : fields,
            desiredMethod: .opportunistic
        )
        lxMessage.method = .opportunistic
        lxMessage.fallbackMethod = fallbackForLargeMessages

        // Use a canonical-width local ID so failed rows remain retryable after
        // reload. A retry reuses its existing ID and atomically replaces that
        // row instead of accumulating stale failed copies.
        let optimisticHash = localRetryHash ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let optimisticId = optimisticHash.map { String(format: "%02x", $0) }.joined()
        lxMessage.hash = optimisticHash

        // A retry must stop being durably retryable before the wire send starts.
        // A new conversation view recovers an interrupted `.sending` row as a
        // visible failure with an unknown-delivery warning.
        if let storedHash = replacedStorageHash ?? localRetryHash {
            lxMessage.state = .sending
            do {
                try await repository.stageRetry(lxMessage, replacing: storedHash)
            } catch {
                errorMessage = "The failed message could not be prepared for retry. Please try again."
                return false
            }
        }

        // Build reply preview for optimistic display
        let replyPreview: String? = {
            guard let replyToId else { return nil }
            if let msg = messages.first(where: { $0.id == replyToId }) {
                return String(msg.content.prefix(80))
            }
            return nil
        }()

        // Create UI message for immediate display (include attachments for preview)
        let optimisticMessage = Message(
            id: optimisticId,
            content: trimmedText,
            timestamp: Date(),
            isFromMe: true,
            deliveryStatus: .sending,
            imageData: imageData,
            imageFormat: imageFormat,
            attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) },
            replyToId: replyToId,
            replyToPreview: replyPreview,
            storageHash: localRetryHash,
            isTargetSafe: false
        )

        // Add to UI immediately, or replace the existing failed row in place.
        withAnimation(.easeOut(duration: 0.25)) {
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                messages[index] = optimisticMessage
                messages[index].messageHash = nil
            } else {
                messages.append(optimisticMessage)
                messages[messages.count - 1].messageHash = nil
            }
        }
        unpersistedOutboundIDs.insert(optimisticId)

        do {
            // Send through the neutral LXMF facet with TYPED fields (image /
            // attachments / icon) — the backend builds the canonical LXMF field
            // map + routes, and returns the real message hash. (Replaces the old
            // Compat router + sendHook path, which dropped all fields on the
            // wire.) Nothing persists the outbound message to the local DB, so
            // we save explicitly below once `lxMessage.hash` is stamped.
            let outcome = try await sendOutbound(
                OutboundSendRequest(
                    destHashHex: Self.hexString(conversationHash),
                    content: trimmedText,
                    method: .opportunistic,
                    failureFallbackMethod: retryViaRelay ? .propagated : nil,
                    imageData: imageData,
                    imageFormat: imageFormat,
                    fileAttachments: attachments?.map {
                        RnsFileAttachment(name: $0.name, data: $0.data)
                    },
                    iconAppearance: icon,
                    replyToMessageHashHex: replyToId,
                    replyQuotedContent: replyPreview,
                    extraFields: nil
                ),
                backend: backend
            )
            let sentHash = try Self.queuedHash(from: outcome)
            lxMessage.hash = sentHash
            lxMessage.state = .sent
            registerPendingOutboundAlias(
                canonicalHash: sentHash,
                optimisticID: optimisticId
            )

            // Persist so a subsequent loadMessages() doesn't wipe it.
            do {
                try await persistMessage(lxMessage, replacing: localRetryHash)
                await reconcilePendingDeliveryProof(for: sentHash)
                unpersistedOutboundIDs.remove(optimisticId)
                unsavedFailedOutboundIDs.remove(optimisticId)
                stagedRetryRecoveryHashes.removeValue(forKey: optimisticId)
                await invalidatePaginationAndRefresh()
            } catch {
                let proof = pendingDeliveryProof(for: sentHash)
                let recovered = await recoverStagedRetryAfterPersistenceFailure(
                    localRetryHash,
                    canonicalHash: sentHash
                )
                if localRetryHash != nil && recovered {
                    unpersistedOutboundIDs.remove(optimisticId)
                    unsavedFailedOutboundIDs.remove(optimisticId)
                } else {
                    unsavedFailedOutboundIDs.insert(optimisticId)
                    if let localRetryHash {
                        stagedRetryRecoveryHashes[optimisticId] = localRetryHash
                    }
                }
                logger.error("[MSG_VM] saveMessage(outbound) failed: \(error.localizedDescription)")
                if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                    messages[index].messageHash = sentHash
                    messages[index].deliveryStatus = proof.map { Self.deliveryStatus(for: $0.state) } ?? .failed
                }
                errorMessage = "Message was sent, but local confirmation could not be saved. Verify whether it arrived before retrying."
            }

            return true
        } catch {
            var failure: Error = error
            // Retry via relay if enabled
            if retryViaRelay {
                logger.info("[MSG_VM] Delivery failed, retrying via relay")

                // Update UI to show retrying
                if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages[index].deliveryStatus = .sending
                    }
                }

                // Create new message with propagated method
                let retryMessage = LXMessage(
                    destinationHash: conversationHash,
                    sourceIdentity: identity,
                    content: trimmedText.data(using: .utf8) ?? Data(),
                    title: Data(),
                    fields: fields.isEmpty ? nil : fields,
                    desiredMethod: .propagated
                )

                do {
                    // Relay retry through the neutral facet (propagated method).
                    let retryOutcome = try await sendOutbound(
                        OutboundSendRequest(
                            destHashHex: Self.hexString(conversationHash),
                            content: trimmedText,
                            method: .propagated,
                            failureFallbackMethod: nil,
                            imageData: imageData,
                            imageFormat: imageFormat,
                            fileAttachments: attachments?.map {
                                RnsFileAttachment(name: $0.name, data: $0.data)
                            },
                            iconAppearance: icon,
                            replyToMessageHashHex: replyToId,
                            replyQuotedContent: replyPreview,
                            extraFields: nil
                        ),
                        backend: backend
                    )
                    let retryHash = try Self.queuedHash(from: retryOutcome)
                    retryMessage.hash = retryHash
                    retryMessage.state = .sent
                    retryMessage.method = .propagated
                    registerPendingOutboundAlias(
                        canonicalHash: retryHash,
                        optimisticID: optimisticId
                    )
                    do {
                        try await persistMessage(retryMessage, replacing: localRetryHash)
                        await reconcilePendingDeliveryProof(for: retryHash)
                        unpersistedOutboundIDs.remove(optimisticId)
                        unsavedFailedOutboundIDs.remove(optimisticId)
                        stagedRetryRecoveryHashes.removeValue(forKey: optimisticId)
                        await invalidatePaginationAndRefresh()
                    } catch {
                        let proof = pendingDeliveryProof(for: retryHash)
                        let recovered = await recoverStagedRetryAfterPersistenceFailure(
                            localRetryHash,
                            canonicalHash: retryHash
                        )
                        if localRetryHash != nil && recovered {
                            unpersistedOutboundIDs.remove(optimisticId)
                            unsavedFailedOutboundIDs.remove(optimisticId)
                        } else {
                            unsavedFailedOutboundIDs.insert(optimisticId)
                            if let localRetryHash {
                                stagedRetryRecoveryHashes[optimisticId] = localRetryHash
                            }
                        }
                        logger.error("[MSG_VM] saveMessage(retry-relay) failed: \(error.localizedDescription)")
                        if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                            messages[index].messageHash = retryHash
                            messages[index].deliveryStatus = proof.map { Self.deliveryStatus(for: $0.state) } ?? .failed
                        }
                        errorMessage = "Message was relayed, but local confirmation could not be saved. Verify whether it arrived before retrying."
                    }
                    return true
                } catch {
                    failure = error
                    logger.error("[MSG_VM] Relay retry also failed: \(error.localizedDescription)")
                }
            }

            // Failed outbound attempts are still conversation activity. Persist
            // the failed row so it remains visible on Chats and can be retried.
            lxMessage.state = .failed
            // This hash was generated locally and was never accepted by a
            // backend. Persist that provenance explicitly: 32-byte width alone
            // must not make a reloaded row safe for replies or reactions.
            lxMessage.receivingInterface = MessageRepository.optimisticOutboundMarker
            var persisted = false
            do {
                try await persistMessage(lxMessage, replacing: localRetryHash)
                persisted = true
                unpersistedOutboundIDs.remove(optimisticId)
                unsavedFailedOutboundIDs.remove(optimisticId)
                stagedRetryRecoveryHashes.removeValue(forKey: optimisticId)
                await invalidatePaginationAndRefresh()
            } catch {
                let recovered = await recoverStagedRetryAfterPersistenceFailure(
                    localRetryHash,
                    canonicalHash: nil
                )
                persisted = localRetryHash != nil && recovered
                if localRetryHash != nil && recovered {
                    unpersistedOutboundIDs.remove(optimisticId)
                    unsavedFailedOutboundIDs.remove(optimisticId)
                } else {
                    unsavedFailedOutboundIDs.insert(optimisticId)
                    if let localRetryHash {
                        stagedRetryRecoveryHashes[optimisticId] = localRetryHash
                    }
                }
                logger.error("[MSG_VM] saveMessage(failed) failed: \(error.localizedDescription)")
            }

            // Update to failed status with real hash so retry can delete from DB
            let realHash = lxMessage.hash
            let failedId = realHash.map { String(format: "%02x", $0) }.joined()
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    messages[index].deliveryStatus = .failed
                    messages[index].messageHash = realHash
                    if !failedId.isEmpty {
                        messages[index] = Message(
                            id: failedId,
                            content: messages[index].content,
                            timestamp: messages[index].timestamp,
                            isFromMe: true,
                            deliveryStatus: .failed,
                            imageData: imageData,
                            imageFormat: imageFormat,
                            attachments: attachments?.map { FileAttachment(name: $0.name, data: $0.data) },
                            replyToId: replyToId,
                            replyToPreview: replyPreview
                        )
                        messages[index].messageHash = realHash
                    }
                }
            }
            let category = Self.failureCategory(failure)
            DiagLog.log("[MSG_SEND] failed category=\(category) persisted=\(persisted)")
            if persisted {
                errorMessage = "Message failed: \(failure.localizedDescription) It was saved for retry."
            } else {
                errorMessage = "Message failed: \(failure.localizedDescription) It could not be saved locally."
            }
            return false
        }
    }

    /// Retry sending a failed message.
    @MainActor
    public func retryMessage(messageId: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].deliveryStatus == .failed else {
            return
        }

        var failedMessage = messages[index]
        if unsavedFailedOutboundIDs.contains(messageId),
           let stagedHash = stagedRetryRecoveryHashes[messageId] {
            do {
                try await repository.recoverStagedRetry(
                    stagedHash,
                    canonicalHash: failedMessage.messageHash
                )
                stagedRetryRecoveryHashes.removeValue(forKey: messageId)
                unsavedFailedOutboundIDs.remove(messageId)
                unpersistedOutboundIDs.remove(messageId)
                let storedRecovered = try await repository.getMessageRecord(id: stagedHash)
                guard let recoveredRecord = storedRecovered,
                      recoveredRecord.state == LXMessageState.failed.rawValue,
                      MessageRepository.isUncertainRetryMarker(
                        recoveredRecord.receivingInterface
                      ) else {
                    await invalidatePaginationAndRefresh()
                    return
                }
                failedMessage = Message(
                    from: recoveredRecord,
                    localHash: appServices.localIdentityHash
                )
                await invalidatePaginationAndRefresh()
            } catch {
                errorMessage = "The staged retry could not be recovered. Please try again."
                return
            }
        } else if unsavedFailedOutboundIDs.contains(messageId) {
            clearPendingAliases(for: messageId)
            unsavedFailedOutboundIDs.remove(messageId)
            unpersistedOutboundIDs.remove(messageId)
            messages.removeAll { $0.id == messageId }
            _ = await sendMessage(
                text: failedMessage.content,
                imageData: failedMessage.imageData,
                imageFormat: failedMessage.imageFormat,
                attachments: failedMessage.attachments?.map { (name: $0.name, data: $0.data) },
                replyToId: failedMessage.replyToId
            )
            return
        }

        let storedHash = failedMessage.storageHash
            ?? failedMessage.messageHash
            ?? Self.hexToData(failedMessage.id)
        let retryHash: Data
        if let storedHash, storedHash.count == 32 {
            retryHash = storedHash
        } else {
            retryHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        }

        // Reuse a canonical local ID and the complete payload. The send path
        // replaces the failed row only after the replacement is safely saved,
        // including migration of legacy non-32-byte temporary IDs.
        clearPendingAliases(for: messageId)
        _ = await sendMessage(
            text: failedMessage.content,
            imageData: failedMessage.imageData,
            imageFormat: failedMessage.imageFormat,
            attachments: failedMessage.attachments?.map { (name: $0.name, data: $0.data) },
            replyToId: failedMessage.replyToId,
            localRetryHash: retryHash,
            replacedStorageHash: storedHash
        )
        let retryId = retryHash.map { String(format: "%02x", $0) }.joined()
        if retryId != messageId, messages.contains(where: { $0.id == retryId }) {
            messages.removeAll { $0.id == messageId }
        }
    }

    /// Whether a message has reached durable storage and can be deleted safely.
    public func canDeleteMessage(messageId: String) -> Bool {
        Self.canDeleteMessage(
            isUnpersisted: unpersistedOutboundIDs.contains(messageId),
            isUnsavedFailure: unsavedFailedOutboundIDs.contains(messageId)
        )
    }

    public func canTargetMessage(messageId: String) -> Bool {
        guard !unpersistedOutboundIDs.contains(messageId),
              let message = messages.first(where: { $0.id == messageId }) else { return false }
        return message.isTargetSafe
    }

    static func canDeleteMessage(
        isUnpersisted: Bool,
        isUnsavedFailure: Bool
    ) -> Bool {
        !isUnpersisted || isUnsavedFailure
    }

    /// Delete a message from the conversation.
    @MainActor
    public func deleteMessage(messageId: String, messageHash: Data?) async {
        guard canDeleteMessage(messageId: messageId) else { return }
        let visibleMessage = messages.first(where: { $0.id == messageId })
        let durableHash = visibleMessage?.storageHash ?? messageHash

        var wasUnsavedFailure = unsavedFailedOutboundIDs.contains(messageId)
        if wasUnsavedFailure, let stagedHash = stagedRetryRecoveryHashes[messageId] {
            do {
                try await repository.recoverStagedRetry(
                    stagedHash,
                    canonicalHash: visibleMessage?.messageHash
                )
                wasUnsavedFailure = false
            } catch {
                errorMessage = "The staged retry could not be recovered for deletion. Please try again."
                return
            }
        }

        unsavedFailedOutboundIDs.remove(messageId)
        unpersistedOutboundIDs.remove(messageId)
        stagedRetryRecoveryHashes.removeValue(forKey: messageId)
        clearPendingAliases(for: messageId)

        // Remove from UI immediately
        withAnimation {
            messages.removeAll { $0.id == messageId }
        }

        if wasUnsavedFailure {
            await invalidatePaginationAndRefresh()
            return
        }

        // Delete from database if we have the durable storage key.
        if let hash = durableHash {
            do {
                try await repository.deleteMessage(hash)
                await invalidatePaginationAndRefresh()
            } catch {
                logger.error("Failed to delete message: \(error.localizedDescription)")
            }
        }
    }

    /// Check if a message is from the local user.
    public func isMessageFromMe(_ message: Message) -> Bool {
        message.isFromMe
    }

    // MARK: - Reactions

    /// Send an emoji reaction to a message (toggle: adds if not present, removes if present).
    @MainActor
    public func sendReaction(targetMessageId: String, targetMessageHash: Data?, emoji: String) async {
        guard let target = messages.first(where: { $0.id == targetMessageId }),
              target.isTargetSafe,
              let canonicalHash = target.messageHash,
              canonicalHash == targetMessageHash else { return }
        let storageHash = target.storageHash ?? canonicalHash
        guard let backend = appServices.backend else { return }

        let localHashHex = appServices.localIdentityHash.map { String(format: "%02x", $0) }.joined()

        // Serialize the database read/modify/write with every incoming reaction
        // merge. This prevents a stale local snapshot from erasing a visible
        // reaction or its durable replay-ledger entry.
        var committedReactions: [String: [String]]?
        do {
            committedReactions = try await ReactionMutationGate.shared.withLock {
                var reactionsDict: [String: [String]] = [:]
                if let json = try await repository.getReactionsJson(storageHash),
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
                    reactionsDict = dict
                }

                var senders = reactionsDict[emoji] ?? []
                if senders.contains(localHashHex) {
                    senders.removeAll { $0 == localHashHex }
                } else {
                    senders.append(localHashHex)
                }
                if senders.isEmpty {
                    reactionsDict.removeValue(forKey: emoji)
                } else {
                    reactionsDict[emoji] = senders
                }

                let jsonData = try JSONSerialization.data(withJSONObject: reactionsDict)
                let jsonStr = String(decoding: jsonData, as: UTF8.self)
                try await repository.updateReactions(storageHash, reactionsJson: jsonStr)
                return reactionsDict
            }
        } catch {
            logger.error("Failed to persist local reaction: \(error.localizedDescription)")
        }

        // Update UI only from a successfully committed database state.
        if let reactionsDict = committedReactions,
           let index = messages.firstIndex(where: { $0.id == targetMessageId }) {
            withAnimation(.easeInOut(duration: 0.15)) {
                messages[index].reactions = ReactionLedger.visibleReactions(reactionsDict).map { emojiKey, senderList in
                    ReactionDisplay(
                        emoji: emojiKey,
                        count: senderList.count,
                        includesMe: senderList.contains(localHashHex)
                    )
                }.sorted { $0.emoji < $1.emoji }
            }
        }

        // Send via the canonical FIELD_REACTION (0x40): the backend builds the
        // {0x00: targetHashBytes, 0x01: emojiUTF8} dict on an empty-content
        // message; the reacting user is derived from the source hash on receive
        // (not on the wire). Replaces the legacy 0x10 {reaction_to,emoji,sender}.
        do {
            try await backend.lxmf.sendReaction(
                destHashHex: conversationHash.map { String(format: "%02x", $0) }.joined(),
                targetMessageHashHex: Self.hexString(canonicalHash),
                emoji: emoji)
        } catch {
            logger.error("Failed to send reaction: \(error.localizedDescription)")
        }
    }

    // MARK: - Reply Preview Resolution

    /// Resolve reply preview text for a message hash (DB fallback when not in loaded messages).
    private func resolveReplyPreview(_ replyToIdHex: String) async -> String? {
        guard let hashData = Self.hexToData(replyToIdHex) else { return nil }
        guard let record = try? await repository.getMessageRecord(id: hashData) else { return nil }
        guard let content = String(data: record.content, encoding: .utf8), !content.isEmpty else { return nil }
        return String(content.prefix(80))
    }

    /// Convert hex string to Data.
    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var chars = hex[hex.startIndex...]
        while chars.count >= 2 {
            let end = chars.index(chars.startIndex, offsetBy: 2)
            guard let byte = UInt8(chars[chars.startIndex..<end], radix: 16) else { return nil }
            data.append(byte)
            chars = chars[end...]
        }
        return data
    }
}
