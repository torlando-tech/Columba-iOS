//
//  ChatsViewModel.swift
//  Columba-iOS
//
//  ViewModel for the chats screen using @Observable macro.
//  Manages conversation list data from MessageRepository.
//

import Foundation
import RNSAPI
import Observation

// MARK: - Conversation Model

public enum ConversationPreviewKind: Equatable, Hashable, Sendable {
    case message
    case draft
}

/// Represents a conversation in the chats list.
/// Wraps ConversationRecord from LXMFSwift with UI-specific properties.
public struct Conversation: Identifiable, Equatable, Hashable {
    public let id: String
    public let destinationHash: Data
    public var displayName: String?
    public var lastMessageTimestamp: Date
    public var lastMessagePreview: String?
    public var unreadCount: Int
    public var isFavorite: Bool
    public var iconName: String?
    public var iconFgColor: String?
    public var iconBgColor: String?
    public var draftText: String?
    public var draftUpdatedAt: Date?
    public var previewKind: ConversationPreviewKind

    /// Display name with fallback to truncated hash.
    public var peerName: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        // Fallback: "Peer " + first 8 hex chars uppercase
        let hexString = destinationHash
            .prefix(4)
            .map { String(format: "%02X", $0) }
            .joined()
        return "Peer \(hexString)"
    }

    /// Cached date formatter for old timestamps.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Formatted relative timestamp for display.
    public var relativeTimestamp: String {
        let now = Date()
        let interval = now.timeIntervalSince(lastMessageTimestamp)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d"
        } else {
            return Self.dateFormatter.string(from: lastMessageTimestamp)
        }
    }

    /// Create from LXMFSwift ConversationRecord.
    public init(from record: ConversationRecord) {
        self.id = record.destinationHash.map { String(format: "%02x", $0) }.joined()
        self.destinationHash = record.destinationHash
        self.displayName = record.displayName
        self.lastMessageTimestamp = record.lastMessageTimestamp
        self.lastMessagePreview = record.lastMessagePreview
        self.unreadCount = record.unreadCount
        self.isFavorite = record.isFavorite != 0
        self.iconName = record.iconName
        self.iconFgColor = record.iconFgColor
        self.iconBgColor = record.iconBgColor
        self.draftText = nil
        self.draftUpdatedAt = nil
        self.previewKind = .message
    }

    public init(
        id: String = UUID().uuidString,
        destinationHash: Data,
        displayName: String? = nil,
        lastMessageTimestamp: Date,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0,
        isFavorite: Bool = false,
        draftText: String? = nil,
        draftUpdatedAt: Date? = nil,
        previewKind: ConversationPreviewKind = .message
    ) {
        self.id = id
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.lastMessageTimestamp = lastMessageTimestamp
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
        self.isFavorite = isFavorite
        self.draftText = draftText
        self.draftUpdatedAt = draftUpdatedAt
        self.previewKind = previewKind
    }
}

// MARK: - ChatsViewModel

/// ViewModel for the chats screen.
///
/// Uses iOS 17+ @Observable macro for automatic SwiftUI observation.
/// Fetches conversation data from MessageRepository.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class ChatsViewModel {
    // MARK: - Published Properties

    /// List of conversations, sorted by most recent message first.
    public var conversations: [Conversation] = []

    /// True while loading or refreshing conversations.
    public var isLoading: Bool = false

    /// True while performing a refresh operation.
    public var isRefreshing: Bool = false

    /// Search query text.
    public var searchQuery: String = ""

    /// Error message if load failed, nil otherwise.
    public var errorMessage: String? = nil

    // MARK: - Voice segment state

    /// The active Text|Voice subtab. `.text` is the default on launch.
    public var selectedSegment: ChatsSegment = .text

    /// Search query for the Voice segment (matched against the peer name).
    public var voiceSearchQuery: String = ""

    /// Enriched call-history records for the Voice segment.
    public var voiceRecords: [VoiceCallDisplay] = []

    /// True while loading the Voice history.
    public var voiceIsLoading: Bool = false

    /// Error message if the Voice load failed, nil otherwise.
    public var voiceErrorMessage: String?

    /// The attempt id of the live call (mirrored from `CallManager`), so the
    /// list can mark the matching card "In progress".
    public var activeCallAttemptId: String?

    // MARK: - Computed Properties

    /// Number of conversations for subtitle display.
    public var conversationCountText: String {
        let count = filteredConversations.count
        return count == 1 ? "1 conversation" : "\(count) conversations"
    }

    /// Filtered conversations based on search query.
    public var filteredConversations: [Conversation] {
        guard !searchQuery.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.peerName.localizedCaseInsensitiveContains(searchQuery) ||
            (conversation.lastMessagePreview?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    // MARK: - Dependencies

    private let repository: MessageRepository
    private let notificationObserver: NotificationObserver
    private let pathTable: PathTable?
    private var inProcessObserver: NSObjectProtocol?
    private var conversationReadObserver: NSObjectProtocol?
    private var conversationActivityObserver: NSObjectProtocol?
    private var conversationMetadataObserver: NSObjectProtocol?
    private var draftChangedObserver: NSObjectProtocol?
    private var conversationLoadGeneration: UInt64 = 0
    private var activeConversationLoadCount: Int = 0
    private var activeConversationRefreshCount: Int = 0

    /// Call-history reader for the Voice segment (nil until AppServices wires
    /// it — the Voice tab simply shows nothing when unavailable).
    private let callHistory: CallHistoryRepository?
    /// Hex of the active local identity hash, for identity-scoped reads.
    private let localIdentityHashHex: String?

    // MARK: - Initialization

    public init(repository: MessageRepository,
                notificationObserver: NotificationObserver,
                pathTable: PathTable? = nil,
                callHistory: CallHistoryRepository? = nil,
                localIdentityHashHex: String? = nil) {
        self.repository = repository
        self.notificationObserver = notificationObserver
        self.pathTable = pathTable
        self.callHistory = callHistory
        self.localIdentityHashHex = localIdentityHashHex

        // Register for Darwin notifications (cross-process, fires before DB save)
        notificationObserver.onNewMessage { [weak self] in
            Task { @MainActor in
                await self?.loadConversations()
            }
        }

        // Register for in-process notifications (fires after DB save — this is the reliable one)
        inProcessObserver = NotificationCenter.default.addObserver(
            forName: IncomingMessageHandler.messageReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadConversations()
            }
        }

        conversationReadObserver = NotificationCenter.default.addObserver(
            forName: MessageRepository.conversationReadNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let hash = notification.userInfo?[MessageRepository.conversationHashUserInfoKey] as? Data else {
                return
            }
            Task { @MainActor in
                guard let self else { return }
                self.clearUnreadBadge(for: hash)
                // Replace any invalidated in-flight snapshot with a fresh one
                // captured after the read transaction committed. This keeps the
                // newest preview/timestamp/order while clearing the badge.
                await self.loadConversations()
            }
        }

        conversationActivityObserver = NotificationCenter.default.addObserver(
            forName: MessageRepository.conversationActivityNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadConversations()
            }
        }

        conversationMetadataObserver = NotificationCenter.default.addObserver(
            forName: MessageRepository.conversationMetadataChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadConversations()
            }
        }

        draftChangedObserver = NotificationCenter.default.addObserver(
            forName: MessageRepository.draftChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.loadConversations()
            }
        }
    }

    deinit {
        if let observer = inProcessObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = conversationReadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = conversationActivityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = conversationMetadataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = draftChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Methods

    // MARK: Voice history (issue #167)

    /// Load the identity-scoped call history for the Voice segment and enrich
    /// each record with the LIVE conversation display name + profile icon.
    ///
    /// Enrichment is done here (the "view layer") rather than in the repository:
    /// `CallHistoryRepository` is GRDB-only and must not join `conversations`
    /// (see `CallHistoryRecord`'s doc). The VM already holds `repository`, so it
    /// resolves each remote identity via `fetchConversations(for:)` — the same
    /// source the Text tab reads — and falls back to the stored
    /// `peerDisplayNameSnapshot` when a peer has no conversation row.
    @MainActor
    public func loadVoiceHistory() async {
        guard let hex = localIdentityHashHex, let callHistory else {
            voiceRecords = []
            voiceIsLoading = false
            return
        }
        voiceIsLoading = true
        do {
            // Fetch the full identity-scoped history with an EMPTY query:
            // search filtering happens CLIENT-side against the ENRICHED peer
            // name (`filteredVoiceRecords`), which covers both the live
            // conversation name and the snapshot — a DB LIKE against only the
            // snapshot column would miss a renamed peer.
            let records = try await callHistory.fetchHistory(localIdentityHash: hex, query: "")
            voiceRecords = await enrichVoiceRecords(records)
            voiceErrorMessage = nil
        } catch {
            voiceErrorMessage = error.localizedDescription
        }
        voiceIsLoading = false
    }

    /// Voice history with the live search query applied against the ENRICHED
    /// peer name (the source the Text tab's `filteredConversations` mirrors).
    /// The list renders THIS, so typing in the Voice search bar filters
    /// without a reload.
    public var filteredVoiceRecords: [VoiceCallDisplay] {
        let query = voiceSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return voiceRecords }
        return voiceRecords.filter { $0.peerName.localizedCaseInsensitiveContains(query) }
    }

    /// Resolve each record's remote identity to a live `ConversationRecord`
    /// (name + icon) in one batched fetch, preserving order.
    @MainActor
    private func enrichVoiceRecords(_ records: [CallHistoryRecord]) async -> [VoiceCallDisplay] {
        // Collect distinct, valid remote hashes.
        var dataByHex: [String: Data] = [:]
        var validData = [Data]()
        for record in records {
            guard let data = record.remoteIdentityHashData else { continue }
            if dataByHex[record.remoteIdentityHash] == nil {
                dataByHex[record.remoteIdentityHash] = data
                validData.append(data)
            }
        }
        // One batched lookup.
        var convosByHash: [Data: RNSAPI.ConversationRecord] = [:]
        if !validData.isEmpty {
            let convos = (try? await repository.fetchConversations(for: validData)) ?? []
            for convo in convos {
                convosByHash[convo.destinationHash] = convo
            }
        }
        return records.map { record in
            let hashData = record.remoteIdentityHashData
            let convo = hashData.flatMap { convosByHash[$0] }
            return VoiceCallDisplay(
                record: record,
                displayName: convo?.displayName,
                iconName: convo?.iconName,
                iconFgColor: convo?.iconFgColor,
                iconBgColor: convo?.iconBgColor
            )
        }
    }

    /// Permanently delete the identity's call history, then reload the list.
    @MainActor
    public func clearVoiceHistory() async {
        guard let hex = localIdentityHashHex, let callHistory else { return }
        try? await callHistory.clearHistory(localIdentityHash: hex)
        await loadVoiceHistory()
    }

    // MARK: - Public Methods

    /// Load conversations from storage.
    @MainActor
    public func loadConversations() async {
        let generation = beginLoadingConversations()
        defer { endLoadingConversations() }

        do {
            let convos = try await loadConversationSnapshot()
            applyLoadedConversations(convos, generation: generation)
        } catch {
            if generation == conversationLoadGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Refresh conversations from storage.
    @MainActor
    public func refreshConversations() async {
        let generation = beginRefreshingConversations()
        defer { endRefreshingConversations() }

        do {
            let convos = try await loadConversationSnapshot()
            applyLoadedConversations(convos, generation: generation)
        } catch {
            if generation == conversationLoadGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Capture the visible page together with every committed draft and any
    /// draft parent omitted by that page before projecting one coherent list.
    @MainActor
    private func loadConversationSnapshot() async throws -> [Conversation] {
        async let visibleRecords = repository.fetchConversations()
        async let drafts = repository.fetchDrafts()
        let (visible, committedDrafts) = try await (visibleRecords, drafts)

        let visibleHashes = Set(visible.map(\.destinationHash))
        let missingDraftParentHashes = committedDrafts.keys
            .filter { !visibleHashes.contains($0) }
            .sorted { $0.lexicographicallyPrecedes($1) }
        let missingDraftParents = try await repository.fetchConversations(for: missingDraftParentHashes)

        var recordsByHash: [Data: ConversationRecord] = [:]
        for record in visible + missingDraftParents where recordsByHash[record.destinationHash] == nil {
            recordsByHash[record.destinationHash] = record
        }
        let messageHashes = try await repository.fetchConversationHashesWithMessages(
            for: Array(recordsByHash.keys)
        )

        var conversations = Self.prepareConversations(
            records: Array(recordsByHash.values),
            drafts: committedDrafts,
            conversationHashesWithMessages: messageHashes
        )

        // Backfill display names from path table for conversations that have none.
        if let pathTable {
            for i in conversations.indices where conversations[i].displayName == nil {
                if let entry = await pathTable.lookup(destinationHash: conversations[i].destinationHash),
                   !entry.displayName.isEmpty {
                    conversations[i].displayName = entry.displayName
                    try? await repository.ensureConversation(
                        conversations[i].destinationHash,
                        displayName: entry.displayName
                    )
                }
            }
        }

        return conversations
    }

    /// Toggle favorite status for a conversation and persist to database.
    ///
    /// - Parameter conversation: The conversation to toggle
    @MainActor
    public func toggleFavorite(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        let newValue = !conversations[index].isFavorite
        conversations[index].isFavorite = newValue
        Task {
            try? await repository.setFavorite(conversation.destinationHash, isFavorite: newValue)
        }
    }

    /// Mark a conversation as unread.
    @MainActor
    public func markUnread(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].unreadCount = max(1, conversations[index].unreadCount)
        Task {
            try? await repository.setUnreadCount(conversation.destinationHash, count: 1)
        }
    }

    /// Convert persisted records and drafts to the visible chat list and enforce
    /// newest activity first at the UI boundary, independent of database ordering.
    static func prepareConversations(
        records: [ConversationRecord],
        drafts: [Data: DraftRecord],
        conversationHashesWithMessages: Set<Data>
    ) -> [Conversation] {
        records
            .compactMap { record in
                let hasMessage = conversationHashesWithMessages.contains(record.destinationHash)
                let draft = drafts[record.destinationHash].flatMap { draft in
                    draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft
                }
                guard hasMessage || draft != nil else { return nil }

                var conversation = Conversation(from: record)
                if let draft {
                    conversation.draftText = draft.content
                    conversation.draftUpdatedAt = draft.updatedAt
                    conversation.lastMessagePreview = draft.content
                    conversation.previewKind = .draft
                    if !hasMessage {
                        conversation.lastMessageTimestamp = draft.updatedAt
                    }
                }
                return conversation
            }
            .sorted {
                if $0.lastMessageTimestamp != $1.lastMessageTimestamp {
                    return $0.lastMessageTimestamp > $1.lastMessageTimestamp
                }
                return $0.id < $1.id
            }
    }

    /// Preserve the original projection call for existing clients while routing
    /// all list preparation through the draft-aware implementation. This legacy
    /// no-draft entry point retains preview-based filtering only for callers that
    /// do not project drafts; production draft projection always supplies the
    /// canonical persisted-message set.
    static func prepareConversations(_ records: [ConversationRecord]) -> [Conversation] {
        prepareConversations(
            records: records,
            drafts: [:],
            conversationHashesWithMessages: Set(
                records.lazy
                    .filter { !$0.lastMessagePreview.isEmpty }
                    .map(\.destinationHash)
            )
        )
    }

    /// Start a list refresh. Only the latest generation may replace the
    /// visible list, preventing slower notification-driven loads from winning.
    @MainActor
    func beginConversationLoad() -> UInt64 {
        conversationLoadGeneration &+= 1
        return conversationLoadGeneration
    }

    /// Track overlapping ordinary loads independently from refresh operations.
    @MainActor
    func beginLoadingConversations() -> UInt64 {
        activeConversationLoadCount += 1
        isLoading = true
        return beginConversationLoad()
    }

    @MainActor
    func endLoadingConversations() {
        activeConversationLoadCount = max(0, activeConversationLoadCount - 1)
        isLoading = activeConversationLoadCount > 0
    }

    /// Track pull-to-refresh/tool-bar refreshes separately so a newer ordinary
    /// load cannot strand or prematurely clear the refresh indicator.
    @MainActor
    func beginRefreshingConversations() -> UInt64 {
        activeConversationRefreshCount += 1
        isRefreshing = true
        return beginConversationLoad()
    }

    @MainActor
    func endRefreshingConversations() {
        activeConversationRefreshCount = max(0, activeConversationRefreshCount - 1)
        isRefreshing = activeConversationRefreshCount > 0
    }

    /// Apply a loaded snapshot only if no newer activity or read-state change
    /// has invalidated it.
    @MainActor
    func applyLoadedConversations(_ loaded: [Conversation], generation: UInt64) {
        guard generation == conversationLoadGeneration else { return }
        conversations = loaded
        errorMessage = nil
    }

    /// Clear the list's cached badge after the repository confirms the read
    /// state was persisted. This avoids showing stale unread counts on return.
    @MainActor
    private func clearUnreadBadge(for conversationHash: Data) {
        // A load may already hold a snapshot captured before the database read
        // completed. Invalidate it before clearing the visible badge so that
        // stale snapshot cannot restore the unread count afterward.
        conversationLoadGeneration &+= 1
        guard let index = conversations.firstIndex(where: { $0.destinationHash == conversationHash }) else {
            return
        }
        conversations[index].unreadCount = 0
    }

    /// Delete a conversation.
    ///
    /// - Parameter conversation: The conversation to delete
    @MainActor
    public func deleteConversation(_ conversation: Conversation) async {
        do {
            try await repository.deleteConversation(conversation.destinationHash)
            conversations.removeAll { $0.id == conversation.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
