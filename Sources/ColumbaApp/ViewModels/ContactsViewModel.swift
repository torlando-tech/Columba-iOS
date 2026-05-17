//
//  ContactsViewModel.swift
//  Columba-iOS
//
//  ViewModel for the Contacts screen with My Contacts and Network tabs.
//  Uses @Observable macro for SwiftUI observation.
//

import Foundation
import RNSAPI
import Observation

// MARK: - Contact Type

/// Type of contact badge.
public enum ContactBadgeType: String, Sendable, Equatable, Hashable {
    case peer = "Peer"
    case relay = "RELAY"
    case audio = "Audio"
    case node = "Node"
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
    public let isPinned: Bool
    public let isRelay: Bool
    public var iconName: String?
    public var iconFgColor: String?
    public var iconBgColor: String?
    public let interfaceId: String?
    public let aspect: String?

    /// Icon identifier for the interface this announce was received on.
    /// Returns "bluetooth" (MDI name) for BLE, SF Symbol names for others.
    public var interfaceIcon: String {
        guard let iface = interfaceId else { return "globe" }
        let lower = iface.lowercased()
        // Python-side interface names that get plumbed up here:
        //  - User-defined sections: PythonConfigWriter.sanitize → "Hub-FFB1F1",
        //    "Bluetooth_LE-77CFC2", "Auto_Discovery-7B59DD", etc.
        //  - Dynamically-spawned children with `name=None`: str() form like
        //    "AutoInterfacePeer[en0/fe80::xxxx]", "BLEPeerInterface[]".
        // Both forms need recognizing (case-insensitive substring match).
        if lower.contains("bluetooth") || lower.contains("ble")
            || lower.contains("blepeer") { return "bluetooth" }
        if lower.contains("rnode") { return "antenna.radiowaves.left.and.right" }
        if lower.contains("autointerface") || lower.contains("auto_discovery")
            || lower.contains("autointerfacepeer") { return "wifi" }
        if lower.contains("multipeer") || lower.contains("mpc") { return "apple.logo" }
        return "globe" // tcp and others
    }

    /// Whether this is an LXST telephony (audio/voice call) announce.
    public var isAudio: Bool {
        aspect == "lxst.telephony"
    }

    /// Interface filter category for this contact.
    public var interfaceFilterType: InterfaceFilter {
        guard let iface = interfaceId else { return .tcp }
        let lower = iface.lowercased()
        if lower.contains("bluetooth") || lower.contains("ble")
            || lower.contains("blepeer") { return .ble }
        if lower.contains("rnode") { return .rnode }
        if lower.contains("autointerface") || lower.contains("auto_discovery") { return .wifi }
        if lower.contains("multipeer") || lower.contains("mpc") { return .wifi }
        return .tcp
    }

    /// Display name with fallback to "Peer <hash prefix>" (matches Android Columba).
    public var resolvedDisplayName: String {
        displayName ?? "Peer \(String(identityHashHex.prefix(8)).uppercased())"
    }

    /// Truncated hex hash for display (first 24 chars + ...).
    public var truncatedHash: String {
        let hex = identityHashHex
        if hex.count > 24 {
            return String(hex.prefix(24)) + "..."
        }
        return hex
    }

    /// Cached formatter for relative time strings.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Formatted time ago string.
    public var timeAgo: String {
        Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date())
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

    /// Create a copy with optional field overrides.
    public func copy(
        displayName: String?? = nil,
        badgeType: ContactBadgeType? = nil,
        hopCount: Int? = nil,
        signalStrength: Int? = nil,
        isFavorite: Bool? = nil,
        isPinned: Bool? = nil,
        isRelay: Bool? = nil
    ) -> Contact {
        Contact(
            id: id,
            displayName: displayName ?? self.displayName,
            identityHash: identityHash, identityHashHex: identityHashHex,
            badgeType: badgeType ?? self.badgeType,
            hopCount: hopCount ?? self.hopCount,
            signalStrength: signalStrength ?? self.signalStrength,
            timestamp: timestamp, isOnline: isOnline,
            isFavorite: isFavorite ?? self.isFavorite,
            isPinned: isPinned ?? self.isPinned,
            isRelay: isRelay ?? self.isRelay,
            iconName: iconName, iconFgColor: iconFgColor, iconBgColor: iconBgColor,
            interfaceId: interfaceId, aspect: aspect
        )
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
        self.isPinned = false
        self.interfaceId = entry.interfaceId
        self.aspect = entry.detectedAspect

        // Detect announce type via aspect check or appData parsing
        if entry.isLXMFPropagationNode {
            self.badgeType = .relay
            self.isRelay = true
        } else if let appData = entry.appData,
                  let _ = PropagationNodeInfo.parse(from: appData) {
            self.badgeType = .relay
            self.isRelay = true
        } else if entry.isLXSTTelephony {
            self.badgeType = .audio
            self.isRelay = false
        } else if entry.detectedAspect == "nomadnetwork.node" {
            self.badgeType = .node
            self.isRelay = false
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
        self.signalStrength = 4
        self.timestamp = record.lastMessageTimestamp
        self.isOnline = true
        self.isFavorite = record.isFavorite != 0
        self.isPinned = record.isPinned != 0
        self.isRelay = false
        self.iconName = record.iconName
        self.iconFgColor = record.iconFgColor
        self.iconBgColor = record.iconBgColor
        self.interfaceId = nil
        self.aspect = nil
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
        isPinned: Bool = false,
        isRelay: Bool,
        iconName: String? = nil,
        iconFgColor: String? = nil,
        iconBgColor: String? = nil,
        interfaceId: String? = nil,
        aspect: String? = nil
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
        self.isPinned = isPinned
        self.isRelay = isRelay
        self.iconName = iconName
        self.iconFgColor = iconFgColor
        self.iconBgColor = iconBgColor
        self.interfaceId = interfaceId
        self.aspect = aspect
    }
}

// MARK: - Tab Selection

/// Selected tab in contacts view.
public enum ContactsTab: Int, Sendable, Equatable, Hashable {
    case myContacts = 0
    case network = 1
}

/// Filter for network announces by aspect type.
public enum AnnounceFilter: String, Sendable, Equatable, Hashable, CaseIterable {
    case all = "All"
    case peers = "Peers"
    case audio = "Audio"
    case sites = "Sites"
    case relays = "Relays"
}

/// Filter for network announces by received interface.
public enum InterfaceFilter: String, Sendable, Equatable, Hashable, CaseIterable {
    case all = "All"
    case tcp = "TCP"
    case wifi = "WiFi"
    case ble = "BLE"
    case rnode = "RNode"
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

    /// Buffered new announces that haven't been merged into the visible
    /// list yet. The Network tab pushes incoming announces here instead
    /// of inserting them inline so the rendered order stays stable while
    /// the user is scrolling — a "show N new" pill at the top flushes.
    public var pendingAnnounces: [Contact] = []

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

    /// Network announces aspect filter.
    public var announceFilter: AnnounceFilter = .peers

    /// Network announces interface filter.
    public var interfaceFilter: InterfaceFilter = .all

    /// Currently selected relay node hash (lxmf.propagation aspect, from PropagationNodeManager).
    public var selectedRelayHash: Data?

    /// Delivery destination hash for the selected relay (lxmf.delivery aspect).
    /// Used to match the relay against myContacts which use delivery hashes.
    public var selectedRelayDeliveryHash: Data?

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

    /// Filtered network announces based on search, aspect filter, and interface filter.
    public var filteredNetworkAnnounces: [Contact] {
        applyAnnounceFilters(to: networkAnnounces)
    }

    /// `pendingAnnounces` filtered by the currently-active announce
    /// filters. Used to drive the "Show N new" pill so the count
    /// reflects how many will actually appear in the visible list
    /// after a flush, not the raw buffer size — otherwise an active
    /// filter (peers / audio / sites / relays / interface / search)
    /// could overstate the pill and surprise the user.
    public var filteredPendingAnnounces: [Contact] {
        applyAnnounceFilters(to: pendingAnnounces)
    }

    /// Apply the active aspect / interface / search filters to a
    /// list of announces. Shared between `filteredNetworkAnnounces`
    /// (drives the rendered list) and `filteredPendingAnnounces`
    /// (drives the pill count) so both stay in sync.
    private func applyAnnounceFilters(to announces: [Contact]) -> [Contact] {
        var results = announces

        // Apply aspect filter
        switch announceFilter {
        case .all:
            break
        case .peers:
            results = results.filter { $0.aspect == "lxmf.delivery" || $0.aspect == nil }
        case .audio:
            results = results.filter { $0.isAudio }
        case .sites:
            results = results.filter { $0.badgeType == .node }
        case .relays:
            results = results.filter { $0.isRelay }
        }

        // Apply interface filter
        if interfaceFilter != .all {
            results = results.filter { $0.interfaceFilterType == interfaceFilter }
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
    /// Looks up the stored relay hash in network announces (propagation hash)
    /// and falls back to matching myContacts by delivery hash.
    public var currentRelayContact: Contact? {
        guard let selectedHash = selectedRelayHash else { return nil }
        // Network announces use propagation destination hash — direct match
        if let c = networkAnnounces.first(where: { $0.identityHash == selectedHash }) {
            return c.copy(badgeType: .relay, isRelay: true)
        }
        // myContacts use delivery destination hash — match via delivery hash
        if let deliveryHash = selectedRelayDeliveryHash,
           let c = myContacts.first(where: { $0.identityHash == deliveryHash }) {
            return c.copy(badgeType: .relay, isRelay: true)
        }
        return nil
    }

    /// My contacts grouped with selected relay at top, then pinned, then all.
    public var groupedMyContacts: [(title: String, contacts: [Contact])] {
        var groups: [(title: String, contacts: [Contact])] = []

        // Show selected relay at top (from PropagationNodeManager, not just isRelay flag)
        if let relay = currentRelayContact {
            let autoLabel = isRelayAutoSelected ? " (auto)" : ""
            groups.append((title: "MY RELAY\(autoLabel)", contacts: [relay]))
        }

        // Exclude the selected relay from remaining contacts (check both propagation and delivery hashes)
        let remaining = filteredMyContacts.filter {
            $0.identityHash != selectedRelayHash &&
            $0.identityHash != selectedRelayDeliveryHash
        }

        // Pinned contacts
        let pinned = remaining.filter { $0.isPinned }
        if !pinned.isEmpty {
            groups.append((title: "PINNED", contacts: pinned))
        }

        // All other contacts
        let others = remaining.filter { !$0.isPinned }
        if !others.isEmpty {
            groups.append((title: "ALL CONTACTS", contacts: others))
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
                handleNewPathEntry(entry)
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
        // Skip unknown destinations (only show LXMF, LXST, NomadNet)
        guard entry.isKnownDestination else { return }

        var contact = Contact(from: entry)

        // Preserve saved-contact state (star filled if already in myContacts)
        let savedContact = myContacts.first(where: { $0.id == contact.id })
        if let savedContact, !contact.isFavorite {
            contact = contact.copy(isFavorite: true, isPinned: savedContact.isPinned)
        }

        if let existingIndex = networkAnnounces.firstIndex(where: { $0.id == contact.id }) {
            // Already visible → update data in place. We deliberately do NOT
            // re-sort here: rearranging the visible list while the user is
            // scrolling the Network tab caused mistaps (#34). Position only
            // refreshes on pull-to-refresh / tab reload / "show new" tap.
            networkAnnounces[existingIndex] = contact
        } else if pendingAnnounces.contains(where: { $0.id == contact.id }) {
            // New announce for an id we've already buffered — just refresh
            // the buffered copy so the eventual flush has the latest data.
            if let i = pendingAnnounces.firstIndex(where: { $0.id == contact.id }) {
                pendingAnnounces[i] = contact
            }
        } else {
            // First time seeing this id since the last user-driven refresh.
            // Hold it in the pending bucket so the visible list keeps its
            // current order; the UI surfaces a banner that flushes on tap.
            pendingAnnounces.append(contact)
        }

        // Update myContacts from this announce — badge, relay state, and
        // hops/signal all flow through PathEntry only, so a contact already
        // saved under the My Contacts tab refreshes the moment a new
        // announce arrives instead of waiting for a manual refresh.
        // (Note: the `networkAnnounces.sort` call removed by #44 used to
        // sit just above this block — sorting on every announce is what
        // caused the scrolling-jumps regression.)
        if let myIndex = myContacts.firstIndex(where: { $0.id == contact.id }) {
            let existing = myContacts[myIndex]
            if existing.badgeType != contact.badgeType
                || existing.hopCount != contact.hopCount
                || existing.signalStrength != contact.signalStrength
                || existing.isRelay != contact.isRelay {
                myContacts[myIndex] = existing.copy(
                    badgeType: contact.badgeType,
                    hopCount: contact.hopCount,
                    signalStrength: contact.signalStrength,
                    isRelay: contact.isRelay
                )
            }
        }

        // Re-sync relay state (auto-select may have picked this new node)
        syncRelayState()
    }

    /// Merge any buffered new announces into the visible list and re-sort.
    /// Called when the user pulls to refresh, taps the "show N new" banner,
    /// or otherwise asks for the latest data.
    @MainActor
    public func flushPendingAnnounces() {
        guard !pendingAnnounces.isEmpty else { return }
        networkAnnounces.append(contentsOf: pendingAnnounces)
        pendingAnnounces.removeAll()
        networkAnnounces.sort { $0.timestamp > $1.timestamp }
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

            // Load network announces from path table (known destinations)
            if let pathTable = appServices.pathTable {
                let entries = await pathTable.allEntries()
                networkAnnounces = entries
                    .filter { $0.isKnownDestination }
                    .map { Contact(from: $0) }
                    .sorted { $0.timestamp > $1.timestamp }
            }
            // Drop only the pending entries that the fresh path-table
            // snapshot already covers. `handleNewPathEntry` is also
            // @MainActor and can interleave with the await above, so a
            // blanket `removeAll()` would silently delete announces
            // that arrived *during* the suspension and aren't in the
            // snapshot yet. Filtering by id keeps those late arrivals
            // queued for the next flush.
            let visibleIds = Set(networkAnnounces.map(\.id))
            pendingAnnounces.removeAll { visibleIds.contains($0.id) }

            // Mark network announces that are already saved contacts
            markSavedContacts()

            // Enrich myContacts badges from network announces (ConversationRecord
            // always creates contacts with .peer badge — cross-reference with path
            // table data so relays keep their .relay badge after restart)
            enrichMyContactBadges()

            // Sync relay state from PropagationNodeManager
            syncRelayState()

            // DEBUG: Log relay state for diagnosing badge bug
            let relayHex = selectedRelayHash.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "nil"
            let relayContacts = networkAnnounces.filter { $0.isRelay }
            let myRelayMatches = myContacts.filter { $0.identityHash == selectedRelayHash }
            let netRelayMatches = networkAnnounces.filter { $0.identityHash == selectedRelayHash }
            DiagLog.log("[CONTACTS] selectedRelayHash=\(relayHex)")
            DiagLog.log("[CONTACTS] networkAnnounces=\(networkAnnounces.count), relays=\(relayContacts.count): \(relayContacts.map { "\($0.resolvedDisplayName)=\($0.identityHashHex.prefix(16))" })")
            DiagLog.log("[CONTACTS] myContacts=\(myContacts.count): \(myContacts.map { "\($0.resolvedDisplayName)=\($0.identityHashHex.prefix(16))(\($0.badgeType.rawValue))" })")
            DiagLog.log("[CONTACTS] relay match in network=\(netRelayMatches.count), in myContacts=\(myRelayMatches.count)")
            if let relay = currentRelayContact {
                DiagLog.log("[CONTACTS] currentRelayContact=\(relay.resolvedDisplayName) badge=\(relay.badgeType.rawValue)")
            } else {
                DiagLog.log("[CONTACTS] currentRelayContact=nil")
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
            networkAnnounces = entries
                .filter { $0.isKnownDestination }
                .map { Contact(from: $0) }
                .sorted { $0.timestamp > $1.timestamp }
        }
        // Drop only the pending entries the fresh path-table snapshot
        // already covers — see `loadContacts` for the same race
        // (handleNewPathEntry can interleave with the await above and
        // queue announces that aren't in the snapshot yet; a blanket
        // removeAll() would silently lose them).
        let visibleIds = Set(networkAnnounces.map(\.id))
        pendingAnnounces.removeAll { visibleIds.contains($0.id) }

        // Mark network announces that are already saved contacts
        markSavedContacts()

        // Enrich myContacts badges from network announces
        enrichMyContactBadges()

        // Sync relay state from PropagationNodeManager
        syncRelayState()

        isLoading = false
    }

    /// Sync relay selection state from PropagationNodeManager.
    @MainActor
    public func syncRelayState() {
        selectedRelayHash = appServices.propagationManager?.selectedNodeHash
        selectedRelayDeliveryHash = appServices.propagationManager?.selectedNodeDeliveryHash
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
                myContacts[index] = contact.copy(isFavorite: true)
            } else {
                // Unfavorited — remove from My Contacts
                myContacts.remove(at: index)
                // Also unmark in network announces
                if let nIndex = networkAnnounces.firstIndex(where: { $0.id == contactId }) {
                    networkAnnounces[nIndex] = networkAnnounces[nIndex].copy(isFavorite: false)
                }
            }
        } else if let contact = networkAnnounces.first(where: { $0.id == contactId }) {
            // Not in myContacts yet (e.g. selected relay) — save it
            Task { await addToContacts(contact) }
        }
    }

    /// Toggle pin status for a contact and persist to database.
    @MainActor
    public func togglePin(for contactId: String) {
        guard let index = myContacts.firstIndex(where: { $0.id == contactId }) else { return }
        let contact = myContacts[index]
        let newValue = !contact.isPinned
        Task {
            try? await messageRepository.setPinned(contact.identityHash, isPinned: newValue)
        }
        myContacts[index] = contact.copy(isPinned: newValue)
    }

    /// Update nickname for a contact and persist to database.
    /// Pass nil to clear the custom nickname (falls back to announce name).
    @MainActor
    public func updateNickname(for contactId: String, nickname: String?) {
        guard let index = myContacts.firstIndex(where: { $0.id == contactId }) else { return }
        let contact = myContacts[index]
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        Task {
            try? await messageRepository.updateDisplayName(contact.identityHash, displayName: newName)
        }
        myContacts[index] = contact.copy(displayName: .some(newName))
        // Also update in network announces
        if let nIndex = networkAnnounces.firstIndex(where: { $0.id == contactId }) {
            networkAnnounces[nIndex] = networkAnnounces[nIndex].copy(displayName: .some(newName))
        }
    }

    /// Remove a contact from My Contacts (unfavorite + remove from list).
    @MainActor
    public func removeContact(contactId: String) {
        guard let index = myContacts.firstIndex(where: { $0.id == contactId }) else { return }
        let contact = myContacts[index]
        Task {
            try? await messageRepository.setFavorite(contact.identityHash, isFavorite: false)
        }
        myContacts.remove(at: index)
        // Unmark in network announces
        if let nIndex = networkAnnounces.firstIndex(where: { $0.id == contactId }) {
            networkAnnounces[nIndex] = networkAnnounces[nIndex].copy(isFavorite: false, isPinned: false)
        }
    }

    /// Send an LXMF delivery announce so peers can discover and message this device.
    @MainActor
    public func sendAnnounce() async {
        isAnnouncing = true
        announceSuccess = false

        do {
            let displayName = await SettingsRepository().getDisplayName()
            try await appServices.sendAllAnnounces(displayName: displayName)
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
            myContacts.append(contact.copy(isFavorite: true))

            // Mark this contact as saved in network announces
            if let index = networkAnnounces.firstIndex(where: { $0.id == contact.id }) {
                networkAnnounces[index] = networkAnnounces[index].copy(isFavorite: true)
            }
        } catch {
            errorMessage = "Failed to add contact: \(error.localizedDescription)"
        }
    }

    // MARK: - QR Code / Deep Link Support

    /// Parse an lxma:// URI string into destination hash and public key.
    ///
    /// Format: `lxma://<32-hex-char-dest-hash>:<128-hex-char-pubkey>`
    /// Returns nil on any validation failure.
    public static func parseLXMA(_ urlString: String) -> (destinationHash: Data, publicKey: Data)? {
        var s = urlString
        // Strip scheme prefix
        if s.hasPrefix("lxma://") {
            s = String(s.dropFirst("lxma://".count))
        } else {
            return nil
        }

        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let hashHex = String(parts[0])
        let pubkeyHex = String(parts[1])

        // Validate lengths: 32 hex chars = 16 bytes hash, 128 hex chars = 64 bytes pubkey
        guard hashHex.count == 32, pubkeyHex.count == 128 else { return nil }

        guard let hashData = Self.hexToData(hashHex),
              let pubkeyData = Self.hexToData(pubkeyHex) else {
            return nil
        }

        return (destinationHash: hashData, publicKey: pubkeyData)
    }

    /// Check if a contact with the given destination hash already exists.
    public func contactExists(_ destinationHash: Data) -> Bool {
        let hex = destinationHash.map { String(format: "%02x", $0) }.joined()
        return myContacts.contains(where: { $0.id == hex }) ||
               networkAnnounces.contains(where: { $0.id == hex && $0.isFavorite })
    }

    /// Add a contact from a QR code scan or deep link.
    @MainActor
    public func addContactFromQR(destinationHash: Data, publicKey: Data, nickname: String?) async {
        let hex = destinationHash.map { String(format: "%02x", $0) }.joined()
        guard !myContacts.contains(where: { $0.id == hex }) else { return }

        do {
            try await messageRepository.ensureConversation(
                destinationHash,
                displayName: nickname
            )
            try await messageRepository.setFavorite(destinationHash, isFavorite: true)

            let contact = Contact(
                id: hex,
                displayName: nickname,
                identityHash: destinationHash,
                identityHashHex: hex,
                badgeType: .peer,
                hopCount: 0,
                signalStrength: 3,
                timestamp: Date(),
                isOnline: false,
                isFavorite: true,
                isRelay: false
            )
            myContacts.append(contact)
        } catch {
            errorMessage = "Failed to add contact: \(error.localizedDescription)"
        }
    }

    /// Convert a hex string to Data. Returns nil if the string contains invalid hex characters.
    private static func hexToData(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }

        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        return data
    }

    /// Enrich myContacts from network announces.
    ///
    /// ConversationRecord has no badge / relay / hops / signal fields, so
    /// Contact(from: ConversationRecord) always produces `badgeType=.peer`,
    /// `hopCount=0`, `signalStrength=4`. Cross-reference with networkAnnounces
    /// (built from PathEntry which has all of these) to restore the correct
    /// values whenever an announce is currently visible.
    @MainActor
    private func enrichMyContactBadges() {
        let announceById = Dictionary(
            networkAnnounces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        myContacts = myContacts.map { contact in
            guard let announce = announceById[contact.id] else { return contact }
            let badgeNeedsUpdate = announce.badgeType != contact.badgeType
            let hopsNeedUpdate = announce.hopCount != contact.hopCount
                || announce.signalStrength != contact.signalStrength
            guard badgeNeedsUpdate || hopsNeedUpdate else { return contact }
            return contact.copy(
                badgeType: announce.badgeType,
                hopCount: announce.hopCount,
                signalStrength: announce.signalStrength,
                isRelay: announce.isRelay
            )
        }
    }

    /// Mark network announces that already exist in my contacts.
    @MainActor
    private func markSavedContacts() {
        let savedById = Dictionary(myContacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        networkAnnounces = networkAnnounces.map { contact in
            if let saved = savedById[contact.id], !contact.isFavorite {
                return contact.copy(isFavorite: true, isPinned: saved.isPinned)
            }
            return contact
        }
    }
}
