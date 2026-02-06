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
import ReticulumSwift

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
    ///
    /// Detects propagation nodes by parsing appData with PropagationNodeInfo.
    public init(from entry: PathEntry) {
        let hex = entry.destinationHash.map { String(format: "%02x", $0) }.joined()
        self.id = hex
        self.displayName = entry.displayName
        self.identityHash = entry.destinationHash
        self.identityHashHex = hex
        self.hopCount = Int(entry.hopCount)
        self.signalStrength = max(1, 4 - Int(entry.hopCount / 2))
        self.timestamp = entry.timestamp
        self.isOnline = Date() < entry.expires
        self.isFavorite = false

        // Detect propagation nodes from appData
        if let appData = entry.appData,
           let _ = PropagationNodeInfo.parse(from: appData) {
            self.badgeType = .relay
            self.isRelay = true
        } else {
            self.badgeType = .peer
            self.isRelay = false
        }
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
        self.isFavorite = record.isFavorite != 0
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

/// Filter for network announces by type.
public enum AnnounceFilter: String, Sendable, Equatable, Hashable, CaseIterable {
    case peers = "Peers"
    case relays = "Relays"
    case all = "All"
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

    /// True while sending an announce.
    public var isAnnouncing = false

    /// Brief feedback after announce succeeds.
    public var announceSuccess = false

    /// Error message if load failed.
    public var errorMessage: String?

    /// Search text.
    public var searchText: String = ""

    /// Network announces filter (default: peers only).
    public var announceFilter: AnnounceFilter = .peers

    /// Currently selected relay node hash (from PropagationNodeManager).
    public var selectedRelayHash: Data?

    /// Whether the relay was auto-selected.
    public var isRelayAutoSelected: Bool = true

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

    /// Filtered network announces based on search and type filter.
    public var filteredNetworkAnnounces: [Contact] {
        var results = networkAnnounces

        // Apply type filter
        switch announceFilter {
        case .peers:
            results = results.filter { !$0.isRelay }
        case .relays:
            results = results.filter { $0.isRelay }
        case .all:
            break
        }

        // Apply search filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            results = results.filter { contact in
                contact.resolvedDisplayName.lowercased().contains(query) ||
                contact.identityHashHex.lowercased().contains(query)
            }
        }

        return results
    }

    /// The currently selected relay contact, if any.
    ///
    /// Looks up the stored relay hash and finds the matching contact
    /// in network announces or my contacts.
    public var currentRelayContact: Contact? {
        guard let selectedHash = selectedRelayHash else { return nil }
        // Check network announces first (relays are usually discovered there)
        if let relay = networkAnnounces.first(where: { $0.identityHash == selectedHash }) {
            return relay
        }
        // Fall back to my contacts
        return myContacts.first(where: { $0.identityHash == selectedHash })
    }

    /// My contacts grouped with selected relay at top.
    public var groupedMyContacts: [(title: String, contacts: [Contact])] {
        var groups: [(title: String, contacts: [Contact])] = []

        // Show selected relay at top (from PropagationNodeManager, not just isRelay flag)
        if let relay = currentRelayContact {
            let autoLabel = isRelayAutoSelected ? " (auto)" : ""
            groups.append((title: "MY RELAY\(autoLabel)", contacts: [relay]))
        }

        // Regular contacts (exclude the selected relay to avoid duplication)
        let regularContacts = filteredMyContacts.filter { $0.identityHash != selectedRelayHash }
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
        var contact = Contact(from: entry)

        // Preserve saved-contact state (star filled if already in myContacts)
        let isSaved = myContacts.contains(where: { $0.id == contact.id })
        if isSaved && !contact.isFavorite {
            contact = Contact(
                id: contact.id, displayName: contact.displayName,
                identityHash: contact.identityHash, identityHashHex: contact.identityHashHex,
                badgeType: contact.badgeType, hopCount: contact.hopCount,
                signalStrength: contact.signalStrength, timestamp: contact.timestamp,
                isOnline: contact.isOnline, isFavorite: true, isRelay: contact.isRelay
            )
        }

        if let existingIndex = networkAnnounces.firstIndex(where: { $0.id == contact.id }) {
            networkAnnounces[existingIndex] = contact
        } else {
            networkAnnounces.insert(contact, at: 0)
        }

        networkAnnounces.sort { $0.timestamp > $1.timestamp }

        // Re-sync relay state (auto-select may have picked this new node)
        syncRelayState()
    }

    // MARK: - Public Methods

    /// Load contacts from storage.
    @MainActor
    public func loadContacts() async {
        isLoading = true
        errorMessage = nil

        do {
            // Load my contacts from favorited conversations only
            let conversations = try await messageRepository.fetchConversations()
            myContacts = conversations
                .filter { $0.isFavorite != 0 }
                .map { Contact(from: $0) }

            // Load network announces from path table
            if let pathTable = appServices.pathTable {
                let entries = await pathTable.allEntries()
                networkAnnounces = entries.map { Contact(from: $0) }
                    .sorted { $0.timestamp > $1.timestamp }
            }

            // Mark network announces that are already saved contacts
            markSavedContacts()

            // Sync relay state from PropagationNodeManager
            syncRelayState()

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

        // Mark network announces that are already saved contacts
        markSavedContacts()

        // Sync relay state from PropagationNodeManager
        syncRelayState()

        isLoading = false
    }

    /// Sync relay selection state from PropagationNodeManager.
    @MainActor
    public func syncRelayState() {
        selectedRelayHash = appServices.propagationManager?.selectedNodeHash
        isRelayAutoSelected = appServices.propagationManager?.autoSelectEnabled ?? true
    }

    /// Toggle favorite status for a contact and persist to database.
    ///
    /// In My Contacts: unfavoriting removes the contact from the list.
    /// In Network Announces: this is unused (addToContacts handles that).
    @MainActor
    public func toggleFavorite(for contactId: String) {
        if let index = myContacts.firstIndex(where: { $0.id == contactId }) {
            let contact = myContacts[index]
            let newValue = !contact.isFavorite
            Task {
                try? await messageRepository.setFavorite(contact.identityHash, isFavorite: newValue)
            }
            if newValue {
                let updated = Contact(
                    id: contact.id, displayName: contact.displayName,
                    identityHash: contact.identityHash, identityHashHex: contact.identityHashHex,
                    badgeType: contact.badgeType, hopCount: contact.hopCount,
                    signalStrength: contact.signalStrength, timestamp: contact.timestamp,
                    isOnline: contact.isOnline, isFavorite: true, isRelay: contact.isRelay
                )
                myContacts[index] = updated
            } else {
                // Unfavorited — remove from My Contacts
                myContacts.remove(at: index)
                // Also unmark in network announces
                if let nIndex = networkAnnounces.firstIndex(where: { $0.id == contactId }) {
                    let c = networkAnnounces[nIndex]
                    networkAnnounces[nIndex] = Contact(
                        id: c.id, displayName: c.displayName,
                        identityHash: c.identityHash, identityHashHex: c.identityHashHex,
                        badgeType: c.badgeType, hopCount: c.hopCount,
                        signalStrength: c.signalStrength, timestamp: c.timestamp,
                        isOnline: c.isOnline, isFavorite: false, isRelay: c.isRelay
                    )
                }
            }
        }
    }

    /// Send an LXMF delivery announce so peers can discover and message this device.
    @MainActor
    public func sendAnnounce() async {
        isAnnouncing = true
        announceSuccess = false

        do {
            let displayName = await SettingsRepository().getDisplayName()
            try await appServices.sendAnnounce(displayName: displayName)
            announceSuccess = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self.announceSuccess = false }
            }
        } catch {
            errorMessage = "Announce failed: \(error.localizedDescription)"
        }

        isAnnouncing = false
    }

    /// Add a network contact to my contacts by creating a conversation and marking as favorite.
    @MainActor
    public func addToContacts(_ contact: Contact) async {
        guard !myContacts.contains(where: { $0.id == contact.id }) else { return }

        do {
            try await messageRepository.ensureConversation(
                contact.identityHash,
                displayName: contact.displayName
            )
            try await messageRepository.setFavorite(contact.identityHash, isFavorite: true)
            let saved = Contact(
                id: contact.id, displayName: contact.displayName,
                identityHash: contact.identityHash, identityHashHex: contact.identityHashHex,
                badgeType: contact.badgeType, hopCount: contact.hopCount,
                signalStrength: contact.signalStrength, timestamp: contact.timestamp,
                isOnline: contact.isOnline, isFavorite: true, isRelay: contact.isRelay
            )
            myContacts.append(saved)

            // Mark this contact as saved in network announces
            if let index = networkAnnounces.firstIndex(where: { $0.id == contact.id }) {
                let c = networkAnnounces[index]
                networkAnnounces[index] = Contact(
                    id: c.id, displayName: c.displayName,
                    identityHash: c.identityHash, identityHashHex: c.identityHashHex,
                    badgeType: c.badgeType, hopCount: c.hopCount,
                    signalStrength: c.signalStrength, timestamp: c.timestamp,
                    isOnline: c.isOnline, isFavorite: true, isRelay: c.isRelay
                )
            }
        } catch {
            errorMessage = "Failed to add contact: \(error.localizedDescription)"
        }
    }

    /// Mark network announces that already exist in my contacts.
    @MainActor
    private func markSavedContacts() {
        let savedIds = Set(myContacts.map { $0.id })
        networkAnnounces = networkAnnounces.map { contact in
            if savedIds.contains(contact.id) && !contact.isFavorite {
                return Contact(
                    id: contact.id, displayName: contact.displayName,
                    identityHash: contact.identityHash, identityHashHex: contact.identityHashHex,
                    badgeType: contact.badgeType, hopCount: contact.hopCount,
                    signalStrength: contact.signalStrength, timestamp: contact.timestamp,
                    isOnline: contact.isOnline, isFavorite: true, isRelay: contact.isRelay
                )
            }
            return contact
        }
    }
}
