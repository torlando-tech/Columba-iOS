//
//  ContactsViewModel.swift
//  Columba-iOS
//
//  ViewModel for the Contacts screen with My Contacts and Network tabs.
//  Uses @Observable macro for SwiftUI observation.
//

import Foundation
import Observation
import LXMFSwift

// MARK: - Contact Type

/// Type of contact badge.
public enum ContactBadgeType: String, Sendable, Equatable, Hashable {
    case peer = "Peer"
    case relay = "RELAY"
}

// MARK: - Contact Model

/// Display model for a contact entry.
public struct Contact: Identifiable, Sendable, Hashable {
    public let id: String
    public let displayName: String?
    public let identityHash: Data
    public let identityHashHex: String
    public let badgeType: ContactBadgeType
    public let hopCount: Int
    public let signalStrength: Int // 0-4 bars
    public let timestamp: Date
    public let isOnline: Bool
    public let isFavorite: Bool
    public let isRelay: Bool

    /// Display name with fallback to "Unknown Peer".
    public var resolvedDisplayName: String {
        displayName ?? "Unknown Peer"
    }

    /// Truncated hex hash for display (first 24 chars + ...).
    public var truncatedHash: String {
        let hex = identityHashHex
        if hex.count > 24 {
            return String(hex.prefix(24)) + "..."
        }
        return hex
    }

    /// Formatted time ago string.
    public var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    /// Hop count description.
    public var hopDescription: String {
        if hopCount == 0 {
            return "Direct"
        } else if hopCount == 1 {
            return "1 hop"
        } else {
            return "\(hopCount) hops"
        }
    }

    /// Create from PathEntry.
    public init(from entry: PathEntry) {
        let hex = entry.destinationHash.map { String(format: "%02x", $0) }.joined()
        self.id = hex
        self.displayName = entry.displayName
        self.identityHash = entry.destinationHash
        self.identityHashHex = hex
        self.badgeType = .peer
        self.hopCount = Int(entry.hopCount)
        // Map hop count to signal strength (0 hops = 4 bars, 5+ hops = 1 bar)
        self.signalStrength = max(1, 4 - Int(entry.hopCount / 2))
        self.timestamp = entry.timestamp
        self.isOnline = Date() < entry.expires
        self.isFavorite = false
        self.isRelay = false
    }

    /// Create from ConversationRecord.
    public init(from record: ConversationRecord) {
        let hex = record.destinationHash.map { String(format: "%02x", $0) }.joined()
        self.id = hex
        self.displayName = record.displayName
        self.identityHash = record.destinationHash
        self.identityHashHex = hex
        self.badgeType = .peer
        self.hopCount = 0
        self.signalStrength = 3
        self.timestamp = Date(timeIntervalSince1970: record.lastMessageTimestamp)
        self.isOnline = true
        self.isFavorite = false
        self.isRelay = false
    }

    public init(
        id: String,
        displayName: String?,
        identityHash: Data,
        identityHashHex: String,
        badgeType: ContactBadgeType,
        hopCount: Int,
        signalStrength: Int,
        timestamp: Date,
        isOnline: Bool,
        isFavorite: Bool,
        isRelay: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.identityHash = identityHash
        self.identityHashHex = identityHashHex
        self.badgeType = badgeType
        self.hopCount = hopCount
        self.signalStrength = signalStrength
        self.timestamp = timestamp
        self.isOnline = isOnline
        self.isFavorite = isFavorite
        self.isRelay = isRelay
    }
}

// MARK: - Tab Selection

/// Selected tab in contacts view.
public enum ContactsTab: Int, Sendable, Equatable, Hashable {
    case myContacts = 0
    case network = 1
}

// MARK: - ViewModel

/// ViewModel for contacts screen.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class ContactsViewModel {
    // MARK: - Published Properties

    /// My saved contacts (from conversations).
    public var myContacts: [Contact] = []

    /// Network announces from the mesh (from path table).
    public var networkAnnounces: [Contact] = []

    /// Currently selected tab.
    public var selectedTab: ContactsTab = .myContacts

    /// Loading state.
    public var isLoading = false

    /// Error message if load failed.
    public var errorMessage: String?

    /// Search text.
    public var searchText: String = ""

    // MARK: - Dependencies

    private let appServices: AppServices
    private let messageRepository: MessageRepository

    /// Task for streaming path updates.
    private var updateTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// Filtered my contacts based on search.
    public var filteredMyContacts: [Contact] {
        guard !searchText.isEmpty else { return myContacts }
        let query = searchText.lowercased()
        return myContacts.filter { contact in
            contact.resolvedDisplayName.lowercased().contains(query) ||
            contact.identityHashHex.lowercased().contains(query)
        }
    }

    /// Filtered network announces based on search.
    public var filteredNetworkAnnounces: [Contact] {
        guard !searchText.isEmpty else { return networkAnnounces }
        let query = searchText.lowercased()
        return networkAnnounces.filter { contact in
            contact.resolvedDisplayName.lowercased().contains(query) ||
            contact.identityHashHex.lowercased().contains(query)
        }
    }

    /// My contacts grouped by relay status.
    public var groupedMyContacts: [(title: String, contacts: [Contact])] {
        let relayContacts = filteredMyContacts.filter { $0.isRelay }
        let regularContacts = filteredMyContacts.filter { !$0.isRelay }

        var groups: [(title: String, contacts: [Contact])] = []

        if !relayContacts.isEmpty {
            groups.append((title: "MY RELAY (auto)", contacts: relayContacts))
        }
        if !regularContacts.isEmpty {
            groups.append((title: "ALL CONTACTS", contacts: regularContacts))
        }

        return groups
    }

    // MARK: - Initialization

    public init(appServices: AppServices, messageRepository: MessageRepository) {
        self.appServices = appServices
        self.messageRepository = messageRepository
    }

    deinit {
        updateTask?.cancel()
    }

    // MARK: - Real-Time Updates

    /// Start listening for real-time path updates.
    @MainActor
    public func startListening() {
        guard let pathTable = appServices.pathTable else { return }

        updateTask?.cancel()
        updateTask = Task {
            for await entry in pathTable.pathUpdates {
                guard !Task.isCancelled else { break }
                await handleNewPathEntry(entry)
            }
        }
    }

    /// Stop listening for updates.
    public func stopListening() {
        updateTask?.cancel()
        updateTask = nil
    }

    /// Handle a new path entry from the stream.
    @MainActor
    private func handleNewPathEntry(_ entry: PathEntry) {
        let contact = Contact(from: entry)

        if let existingIndex = networkAnnounces.firstIndex(where: { $0.id == contact.id }) {
            networkAnnounces[existingIndex] = contact
        } else {
            networkAnnounces.insert(contact, at: 0)
        }

        networkAnnounces.sort { $0.timestamp > $1.timestamp }
    }

    // MARK: - Public Methods

    /// Load contacts from storage.
    @MainActor
    public func loadContacts() async {
        isLoading = true
        errorMessage = nil

        do {
            // Load my contacts from conversations
            let conversations = try await messageRepository.fetchConversations()
            myContacts = conversations.map { Contact(from: $0) }

            // Load network announces from path table
            if let pathTable = appServices.pathTable {
                let entries = await pathTable.allEntries()
                networkAnnounces = entries.map { Contact(from: $0) }
                    .sorted { $0.timestamp > $1.timestamp }
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Refresh announces from the network.
    @MainActor
    public func refreshAnnounces() async {
        isLoading = true
        errorMessage = nil

        if let pathTable = appServices.pathTable {
            let entries = await pathTable.allEntries()
            networkAnnounces = entries.map { Contact(from: $0) }
                .sorted { $0.timestamp > $1.timestamp }
        }

        isLoading = false
    }

    /// Toggle favorite status for a contact.
    @MainActor
    public func toggleFavorite(for contactId: String) {
        if let index = myContacts.firstIndex(where: { $0.id == contactId }) {
            let contact = myContacts[index]
            let updated = Contact(
                id: contact.id,
                displayName: contact.displayName,
                identityHash: contact.identityHash,
                identityHashHex: contact.identityHashHex,
                badgeType: contact.badgeType,
                hopCount: contact.hopCount,
                signalStrength: contact.signalStrength,
                timestamp: contact.timestamp,
                isOnline: contact.isOnline,
                isFavorite: !contact.isFavorite,
                isRelay: contact.isRelay
            )
            myContacts[index] = updated
        }

        if let index = networkAnnounces.firstIndex(where: { $0.id == contactId }) {
            let contact = networkAnnounces[index]
            let updated = Contact(
                id: contact.id,
                displayName: contact.displayName,
                identityHash: contact.identityHash,
                identityHashHex: contact.identityHashHex,
                badgeType: contact.badgeType,
                hopCount: contact.hopCount,
                signalStrength: contact.signalStrength,
                timestamp: contact.timestamp,
                isOnline: contact.isOnline,
                isFavorite: !contact.isFavorite,
                isRelay: contact.isRelay
            )
            networkAnnounces[index] = updated
        }
    }

    /// Add a network contact to my contacts by creating a conversation.
    @MainActor
    public func addToContacts(_ contact: Contact) async {
        guard !myContacts.contains(where: { $0.id == contact.id }) else { return }

        do {
            try await messageRepository.ensureConversation(
                contact.identityHash,
                displayName: contact.displayName
            )
            myContacts.append(contact)
        } catch {
            errorMessage = "Failed to add contact: \(error.localizedDescription)"
        }
    }
}
