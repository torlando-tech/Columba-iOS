//
//  ContactsViewModel.swift
//  Columba-iOS
//
//  ViewModel for the Contacts screen with My Contacts and Network tabs.
//  Uses @Observable macro for SwiftUI observation.
//

import Foundation
import Observation

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
}

// MARK: - Tab Selection

/// Selected tab in contacts view.
public enum ContactsTab: Int, Sendable, Equatable, Hashable {
    case myContacts = 0
    case network = 1
}

// MARK: - ViewModel

/// ViewModel for contacts screen.
@available(iOS 17.0, *)
@Observable
public final class ContactsViewModel {
    // MARK: - Published Properties

    /// My saved contacts.
    public var myContacts: [Contact] = []

    /// Network announces from the mesh.
    public var networkAnnounces: [Contact] = []

    /// Currently selected tab.
    public var selectedTab: ContactsTab = .myContacts

    /// Loading state.
    public var isLoading = false

    /// Error message if load failed.
    public var errorMessage: String?

    /// Search text.
    public var searchText: String = ""

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

    public init() {}

    // MARK: - Public Methods

    /// Load contacts from storage.
    @MainActor
    public func loadContacts() async {
        isLoading = true
        errorMessage = nil

        // In a real app, this would load from database
        // For now, using demo data
        myContacts = Self.sampleMyContacts
        networkAnnounces = Self.sampleNetworkAnnounces

        isLoading = false
    }

    /// Refresh announces from the network.
    @MainActor
    public func refreshAnnounces() async {
        isLoading = true
        errorMessage = nil

        // Simulate network delay
        try? await Task.sleep(nanoseconds: 500_000_000)

        // In a real app, this would query the path table
        networkAnnounces = Self.sampleNetworkAnnounces
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

    /// Add a network contact to my contacts.
    @MainActor
    public func addToContacts(_ contact: Contact) {
        guard !myContacts.contains(where: { $0.id == contact.id }) else { return }
        myContacts.append(contact)
    }

    // MARK: - Sample Data

    private static var sampleMyContacts: [Contact] {
        [
            Contact(
                id: "fc112928258ed5f6b9abd1cf0c8d58f0",
                displayName: "rns.moscow Propag...",
                identityHash: Data(repeating: 0xFC, count: 16),
                identityHashHex: "fc112928258ed5f6b9abd1cf0c8d58f0",
                badgeType: .relay,
                hopCount: 0,
                signalStrength: 4,
                timestamp: Date().addingTimeInterval(-480),
                isOnline: true,
                isFavorite: true,
                isRelay: true
            ),
            Contact(
                id: "db3ffd2575469a78bff6b7c8c183e32a",
                displayName: "Torlando - Columba",
                identityHash: Data(repeating: 0xDB, count: 16),
                identityHashHex: "db3ffd2575469a78bff6b7c8c183e32a",
                badgeType: .peer,
                hopCount: 3,
                signalStrength: 3,
                timestamp: Date().addingTimeInterval(-60),
                isOnline: true,
                isFavorite: false,
                isRelay: false
            ),
        ]
    }

    private static var sampleNetworkAnnounces: [Contact] {
        [
            Contact(
                id: "ae8d8dfcbdbb317c9bb845e9568e3ca1",
                displayName: "Alexander",
                identityHash: Data(repeating: 0xAE, count: 16),
                identityHashHex: "ae8d8dfcbdbb317c9bb845e9568e3ca1",
                badgeType: .peer,
                hopCount: 4,
                signalStrength: 3,
                timestamp: Date(),
                isOnline: true,
                isFavorite: false,
                isRelay: false
            ),
            Contact(
                id: "3a5aedd0b00eed70b082fa59d7d68a79",
                displayName: "HSWro LoRa Conference Bot",
                identityHash: Data(repeating: 0x3A, count: 16),
                identityHashHex: "3a5aedd0b00eed70b082fa59d7d68a79",
                badgeType: .peer,
                hopCount: 5,
                signalStrength: 2,
                timestamp: Date(),
                isOnline: true,
                isFavorite: false,
                isRelay: false
            ),
            Contact(
                id: "00e78bccb2ccc8e266a216b1e2d5475f",
                displayName: "LucienStorm",
                identityHash: Data(repeating: 0x00, count: 16),
                identityHashHex: "00e78bccb2ccc8e266a216b1e2d5475f",
                badgeType: .peer,
                hopCount: 5,
                signalStrength: 2,
                timestamp: Date(),
                isOnline: true,
                isFavorite: false,
                isRelay: false
            ),
            Contact(
                id: "bf79f82d383f1c03978df59c3e552b55",
                displayName: "Echo Bot",
                identityHash: Data(repeating: 0xBF, count: 16),
                identityHashHex: "bf79f82d383f1c03978df59c3e552b55",
                badgeType: .peer,
                hopCount: 2,
                signalStrength: 4,
                timestamp: Date(),
                isOnline: true,
                isFavorite: false,
                isRelay: false
            ),
            Contact(
                id: "1d4998a3ae4b8b703a06262fe62ae832",
                displayName: "BBDXNODE-A1",
                identityHash: Data(repeating: 0x1D, count: 16),
                identityHashHex: "1d4998a3ae4b8b703a06262fe62ae832",
                badgeType: .peer,
                hopCount: 2,
                signalStrength: 4,
                timestamp: Date(),
                isOnline: true,
                isFavorite: false,
                isRelay: false
            ),
        ]
    }
}
