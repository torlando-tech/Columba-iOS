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
    private let logger = Logger(subsystem: "network.columba.Columba", category: "MessagingViewModel")

    /// Observation token for incoming message notifications.
    private var notificationTask: Any?
    private var deliveryTask: Any?
    private var pendingRefresh = false
    private var paginationGeneration: UInt64 = 0
    private var unpersistedOutboundIDs: Set<String> = []
    private var unsavedFailedOutboundIDs: Set<String> = []
    private var stagedRetryCleanupHashes: [String: Data] = [:]
    private var pendingOutboundAliases: [String: String] = [:]
    private var pendingDeliveryProofs: [String: LXMessageState] = [:]

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
            let hashHex = hashData.map { String(format: "%02x", $0) }.joined()
            Task { @MainActor in
                let proofState: LXMessageState = (state == "delivered") ? .delivered : .failed
                let visibleID = Self.visibleMessageID(
                    for: hashHex,
                    aliases: self.pendingOutboundAliases
                )
                if self.pendingOutboundAliases[hashHex] != nil {
                    self.pendingDeliveryProofs[hashHex] = proofState
                }
                guard let index = self.messages.firstIndex(where: { $0.id == visibleID }) else { return }
                self.messages[index].deliveryStatus = (proofState == .delivered) ? .delivered : .failed
            }
        }
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
            }

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

            errorMessage = hasInterruptedRetry
                ? Self.interruptedRetryWarning
                : nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        await runPendingRefreshIfNeeded()
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
    private func removeStagedRetryAfterPersistenceFailure(_ hash: Data?) async -> Bool {
        guard let hash else { return true }
        do {
            try await repository.deleteMessage(hash)
            await invalidatePaginationAndRefresh()
            return true
        } catch {
            logger.error("[MSG_VM] failed to remove staged retry: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    private func reconcilePendingDeliveryProof(for hash: Data) async {
        let hashHex = Self.hexString(hash)
        pendingOutboundAliases.removeValue(forKey: hashHex)
        guard let proof = pendingDeliveryProofs.removeValue(forKey: hashHex) else { return }
        do {
            try await repository.updateMessageState(id: hash, state: proof)
        } catch {
            logger.error("[MSG_VM] failed to persist delivery proof: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func takePendingDeliveryProof(for hash: Data) -> LXMessageState? {
        let hashHex = Self.hexString(hash)
        pendingOutboundAliases.removeValue(forKey: hashHex)
        return pendingDeliveryProofs.removeValue(forKey: hashHex)
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

        guard let identity = appServices.identity else {
            errorMessage = "Identity not initialized"
            return false
        }

        guard let backend = appServices.backend else {
            errorMessage = "Backend not initialized"
            return false
        }


        // Always start with opportunistic (single encrypted packet, no link needed).
        // For large messages that exceed single-packet size, handleOutbound() will
        // auto-fallback using the fallbackMethod (direct or propagated per settings).
        // On failure, retry-via-relay handles the final propagated fallback.
        let settingsMethod = await settingsRepository.getDefaultDeliveryMethod()
        let fallbackForLargeMessages: LXDeliveryMethod = (settingsMethod == "propagated") ? .propagated : .direct

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
            replyToPreview: replyPreview
        )

        // Add to UI immediately, or replace the existing failed row in place.
        withAnimation(.easeOut(duration: 0.25)) {
            if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                messages[index] = optimisticMessage
                messages[index].messageHash = optimisticHash
            } else {
                messages.append(optimisticMessage)
                messages[messages.count - 1].messageHash = optimisticHash
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
            let outcome = try await backend.lxmf.sendLxmfMessage(
                destHashHex: conversationHash.map { String(format: "%02x", $0) }.joined(),
                content: trimmedText, method: .opportunistic,
                imageData: imageData, imageFormat: imageFormat,
                fileAttachments: attachments?.map { RnsFileAttachment(name: $0.name, data: $0.data) },
                iconAppearance: icon,
                replyToMessageHashHex: replyToId, replyQuotedContent: replyPreview, extraFields: nil)
            let sentHash = try Self.queuedHash(from: outcome)
            lxMessage.hash = sentHash
            lxMessage.state = .sent
            pendingOutboundAliases[Self.hexString(sentHash)] = optimisticId

            // Persist so a subsequent loadMessages() doesn't wipe it.
            do {
                try await persistMessage(lxMessage, replacing: localRetryHash)
                await reconcilePendingDeliveryProof(for: sentHash)
                unpersistedOutboundIDs.remove(optimisticId)
                unsavedFailedOutboundIDs.remove(optimisticId)
                stagedRetryCleanupHashes.removeValue(forKey: optimisticId)
                await invalidatePaginationAndRefresh()
            } catch {
                unsavedFailedOutboundIDs.insert(optimisticId)
                let proof = takePendingDeliveryProof(for: sentHash)
                let cleaned = await removeStagedRetryAfterPersistenceFailure(localRetryHash)
                if !cleaned, let localRetryHash {
                    stagedRetryCleanupHashes[optimisticId] = localRetryHash
                }
                logger.error("[MSG_VM] saveMessage(outbound) failed: \(error.localizedDescription)")
                if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                    messages[index].deliveryStatus = (proof == .delivered) ? .delivered : .failed
                }
                errorMessage = "Message was sent, but local confirmation could not be saved. Verify whether it arrived before retrying."
            }

            return true
        } catch {
            var failure: Error = error
            // Retry via relay if enabled
            let retryViaRelay = await settingsRepository.getRetryViaRelay()
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
                    let retryOutcome = try await backend.lxmf.sendLxmfMessage(
                        destHashHex: conversationHash.map { String(format: "%02x", $0) }.joined(),
                        content: trimmedText, method: .propagated,
                        imageData: imageData, imageFormat: imageFormat,
                        fileAttachments: attachments?.map { RnsFileAttachment(name: $0.name, data: $0.data) },
                        iconAppearance: icon,
                        replyToMessageHashHex: replyToId, replyQuotedContent: replyPreview, extraFields: nil)
                    let retryHash = try Self.queuedHash(from: retryOutcome)
                    retryMessage.hash = retryHash
                    retryMessage.state = .sent
                    retryMessage.method = .propagated
                    pendingOutboundAliases[Self.hexString(retryHash)] = optimisticId
                    do {
                        try await persistMessage(retryMessage, replacing: localRetryHash)
                        await reconcilePendingDeliveryProof(for: retryHash)
                        unpersistedOutboundIDs.remove(optimisticId)
                        unsavedFailedOutboundIDs.remove(optimisticId)
                        stagedRetryCleanupHashes.removeValue(forKey: optimisticId)
                        await invalidatePaginationAndRefresh()
                    } catch {
                        unsavedFailedOutboundIDs.insert(optimisticId)
                        let proof = takePendingDeliveryProof(for: retryHash)
                        let cleaned = await removeStagedRetryAfterPersistenceFailure(localRetryHash)
                        if !cleaned, let localRetryHash {
                            stagedRetryCleanupHashes[optimisticId] = localRetryHash
                        }
                        logger.error("[MSG_VM] saveMessage(retry-relay) failed: \(error.localizedDescription)")
                        if let index = messages.firstIndex(where: { $0.id == optimisticId }) {
                            messages[index].deliveryStatus = (proof == .delivered) ? .delivered : .failed
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
            var persisted = false
            do {
                try await persistMessage(lxMessage, replacing: localRetryHash)
                persisted = true
                unpersistedOutboundIDs.remove(optimisticId)
                unsavedFailedOutboundIDs.remove(optimisticId)
                stagedRetryCleanupHashes.removeValue(forKey: optimisticId)
                await invalidatePaginationAndRefresh()
            } catch {
                unsavedFailedOutboundIDs.insert(optimisticId)
                let cleaned = await removeStagedRetryAfterPersistenceFailure(localRetryHash)
                if !cleaned, let localRetryHash {
                    stagedRetryCleanupHashes[optimisticId] = localRetryHash
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

        let failedMessage = messages[index]
        if unsavedFailedOutboundIDs.contains(messageId) {
            if let stagedHash = stagedRetryCleanupHashes[messageId] {
                do {
                    try await repository.deleteMessage(stagedHash)
                    stagedRetryCleanupHashes.removeValue(forKey: messageId)
                    await invalidatePaginationAndRefresh()
                } catch {
                    errorMessage = "The staged retry could not be cleaned up. Please try again."
                    return
                }
            }
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

        let storedHash = failedMessage.messageHash ?? Self.hexToData(failedMessage.id)
        let retryHash: Data
        if let storedHash, storedHash.count == 32 {
            retryHash = storedHash
        } else {
            retryHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        }

        // Reuse a canonical local ID and the complete payload. The send path
        // replaces the failed row only after the replacement is safely saved,
        // including migration of legacy non-32-byte temporary IDs.
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

        let wasUnsavedFailure = unsavedFailedOutboundIDs.contains(messageId)
        if wasUnsavedFailure, let stagedHash = stagedRetryCleanupHashes[messageId] {
            do {
                try await repository.deleteMessage(stagedHash)
            } catch {
                errorMessage = "The staged retry could not be deleted. Please try again."
                return
            }
        }

        unsavedFailedOutboundIDs.remove(messageId)
        unpersistedOutboundIDs.remove(messageId)
        stagedRetryCleanupHashes.removeValue(forKey: messageId)

        // Remove from UI immediately
        withAnimation {
            messages.removeAll { $0.id == messageId }
        }

        if wasUnsavedFailure {
            await invalidatePaginationAndRefresh()
            return
        }

        // Delete from database if we have the hash
        if let hash = messageHash {
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
        guard let hash = targetMessageHash else { return }
        guard let backend = appServices.backend else { return }

        let localHashHex = appServices.localIdentityHash.map { String(format: "%02x", $0) }.joined()

        // Serialize the database read/modify/write with every incoming reaction
        // merge. This prevents a stale local snapshot from erasing a visible
        // reaction or its durable replay-ledger entry.
        var committedReactions: [String: [String]]?
        do {
            committedReactions = try await ReactionMutationGate.shared.withLock {
                var reactionsDict: [String: [String]] = [:]
                if let json = try await repository.getReactionsJson(hash),
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
                try await repository.updateReactions(hash, reactionsJson: jsonStr)
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
                targetMessageHashHex: targetMessageId,
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
