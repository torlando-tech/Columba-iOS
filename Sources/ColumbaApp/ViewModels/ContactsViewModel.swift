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

// MARK: - Announce Feedback

/// Owns the transient success state for network announces.
///
/// Each new success supersedes the previous timeout. The generation check is a
/// second fence behind task cancellation so an obsolete reset can never hide a
/// newer success banner.
@MainActor
@Observable
public final class AnnounceFeedbackState {
    public private(set) var isVisible = false

    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    public nonisolated init() {}

    deinit {
        resetTask?.cancel()
    }

    @discardableResult
    public func show(for duration: Duration = .seconds(3)) -> UInt64 {
        resetTask?.cancel()
        generation &+= 1
        let currentGeneration = generation
        isVisible = true

        resetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.dismiss(ifCurrent: currentGeneration)
        }
        return currentGeneration
    }

    /// Internal seam for deterministic stale-timeout regression tests.
    func dismiss(ifCurrent candidateGeneration: UInt64) {
        guard candidateGeneration == generation else { return }
        isVisible = false
        resetTask = nil
    }
}

// MARK: - Contact Type

/// Type of contact badge.
public enum ContactBadgeType: String, Sendable, Equatable, Hashable {
    case peer = "Peer"
    case relay = "RELAY"
    case audio = "Audio"
    case node = "Node"
    case unsupported = "Unsupported"
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
    /// Returns "bluetooth" (MDI name) for BLE, "lucide:<name>" for Lucide-font
    /// glyphs (e.g. the RNode antenna, matching Android), SF Symbol names for others.
    /// Rendering of each form is handled in ContactCard.interfaceIconView.
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
        if lower.contains("rnode") { return "lucide:antenna" }
        if lower.contains("autointerface") || lower.contains("auto_discovery")
            || lower.contains("autointerfacepeer") { return "wifi" }
        if lower.contains("multipeer") || lower.contains("mpc") { return "apple.logo" }
        return "globe" // tcp and others
    }

    /// Whether this is an LXST telephony (audio/voice call) announce.
    public var isAudio: Bool {
        destinationAspect == .lxstTelephony
    }

    public var destinationAspect: DestinationAspect { DestinationAspect(aspect) }

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
        if let displayName,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        return "Peer \(String(identityHashHex.prefix(8)).uppercased())"
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
        isRelay: Bool? = nil,
        aspect: String?? = nil
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
            interfaceId: interfaceId, aspect: aspect ?? self.aspect
        )
    }

    /// Create from PathEntry.
    ///
    /// Detects propagation nodes by parsing appData with PropagationNodeInfo.
    public init(from entry: PathEntry) {
        let hex = Self.hexString(for: entry.destinationHash)
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

        // Detect announce type purely from the aspect. This mirrors the
        // reference clients exactly: Sideband types each announce by which RNS
        // aspect handler received it (aspect_filter "lxmf.propagation" vs
        // "lxmf.delivery"), and Android does the same via NodeType.fromAspect.
        // Exact aspect is the sole type signal. Legacy boolean flags and
        // app-data shape are retained for compatibility but never authorize a
        // badge or action. Unknown aspects remain explicitly unsupported.
        switch entry.destinationAspect {
        case .lxmfPropagation:
            self.badgeType = .relay
            self.isRelay = true
        case .lxstTelephony:
            self.badgeType = .audio
            self.isRelay = false
        case .nomadNetworkNode:
            self.badgeType = .node
            self.isRelay = false
        case .lxmfDelivery:
            self.badgeType = .peer
            self.isRelay = false
        case .unsupported:
            self.badgeType = .unsupported
            self.isRelay = false
        }
    }

    /// Create from ConversationRecord.
    public init(from record: ConversationRecord) {
        let hex = Self.hexString(for: record.destinationHash)
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
        // Conversation records are keyed by LXMF delivery destinations. This is
        // explicit provenance, not payload-shape inference, so saved/QR contacts
        // remain chat-capable even when no announce is currently cached.
        self.aspect = "lxmf.delivery"
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

    private static let lowercaseHex = Array("0123456789abcdef".utf8)

    /// Avoid `String(format:)` allocation for every byte while materializing
    /// thousands of path-table rows on the main actor.
    private static func hexString(for data: Data) -> String {
        var output = [UInt8]()
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(lowercaseHex[Int(byte >> 4)])
            output.append(lowercaseHex[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
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
    public var networkAnnounces: [Contact] = [] {
        didSet { rebuildFilteredNetworkAnnounces() }
    }

    /// Cached visible result. Rebuilt only when source data or filters change,
    /// never merely because SwiftUI reevaluates the Network tab while scrolling.
    public private(set) var filteredNetworkAnnounces: [Contact] = []

    /// Buffered new announces that haven't been merged into the visible
    /// list yet. The Network tab pushes incoming announces here instead
    /// of inserting them inline so the rendered order stays stable while
    /// the user is scrolling — a "show N new" pill at the top flushes.
    public var pendingAnnounces: [Contact] = [] {
        didSet { rebuildFilteredPendingAnnounces() }
    }

    /// Cached banner result for the same reason as the visible Network list.
    public private(set) var filteredPendingAnnounces: [Contact] = []

    /// Currently selected tab.
    public var selectedTab: ContactsTab = .myContacts

    /// Loading state.
    public var isLoading = false

    /// True while sending an announce.
    public var isAnnouncing = false

    /// Transient feedback shown after a successful network announce.
    public let announceFeedback = AnnounceFeedbackState()

    /// Error message if load failed.
    public var errorMessage: String?

    /// Search text.
    public var searchText: String = "" {
        didSet {
            rebuildFilteredNetworkAnnounces()
            rebuildFilteredPendingAnnounces()
        }
    }

    /// Network announces aspect filter.
    public var announceFilter: AnnounceFilter = .peers {
        didSet {
            rebuildFilteredNetworkAnnounces()
            rebuildFilteredPendingAnnounces()
        }
    }

    /// Network announces interface filter.
    public var interfaceFilter: InterfaceFilter = .all {
        didSet {
            rebuildFilteredNetworkAnnounces()
            rebuildFilteredPendingAnnounces()
        }
    }

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

    /// One-shot task for lightweight saved-contact reconciliation.
    private var favoriteRefreshTask: Task<Void, Never>?

    /// Synchronously registered before reconciliation so a favorite mutation
    /// cannot land in a refresh/subscribe gap.
    private var favoriteObserver: NSObjectProtocol?

    /// Avoid rebuilding thousands of contacts whenever the SwiftUI task
    /// reappears. Explicit pull-to-refresh passes `force: true`.
    private var hasLoadedContacts = false
    private var isContactsLoadInFlight = false
    private var savedContactsGeneration: UInt64 = 0

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

    /// Recompute the cached Network-tab result after a source/filter mutation.
    private func rebuildFilteredNetworkAnnounces() {
        filteredNetworkAnnounces = applyAnnounceFilters(to: networkAnnounces)
    }

    /// Recompute the cached pending-banner result after source/filter changes.
    private func rebuildFilteredPendingAnnounces() {
        filteredPendingAnnounces = applyAnnounceFilters(to: pendingAnnounces)
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
            // Peers == the peer node-type only. Mirrors Android's
            // `nodeType == PEER` (a mutually-exclusive enum): keying on
            // badgeType excludes relays / audio / sites by construction, so a
            // relay can't leak in. The previous aspect-only predicate
            // (aspect == "lxmf.delivery" || aspect == nil) ignored isRelay, so
            // a relay carrying aspect "lxmf.delivery"/nil matched both this
            // filter and .relays and showed up under the default Peers view.
            results = results.filter { $0.badgeType == .peer }
        case .audio:
            // Keyed on badgeType (== .audio iff aspect "lxst.telephony"),
            // symmetric with .peers / .relays / .sites so all four filters
            // discriminate on the single mutually-exclusive node type rather
            // than a mix of badgeType and the aspect-derived isAudio.
            results = results.filter { $0.badgeType == .audio }
        case .sites:
            results = results.filter { $0.badgeType == .node }
        case .relays:
            // Relays == the propagation-node type only, i.e. aspect
            // "lxmf.propagation" (Android's nodeType == PROPAGATION_NODE,
            // Sideband's aspect_filter == "lxmf.propagation"). Keyed on
            // badgeType so the four node types stay mutually exclusive on a
            // single discriminator, symmetric with .peers / .sites. Equivalent
            // to `$0.isRelay` today (Contact.init sets them in lockstep) but
            // removes the footgun of an entry being isRelay && badgeType != .relay.
            results = results.filter { $0.badgeType == .relay }
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
        favoriteRefreshTask?.cancel()
        if let favoriteObserver {
            NotificationCenter.default.removeObserver(favoriteObserver)
        }
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

        if let favoriteObserver {
            NotificationCenter.default.removeObserver(favoriteObserver)
        }
        favoriteObserver = NotificationCenter.default.addObserver(
            forName: MessageRepository.favoriteStatusChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleSavedContactsRefresh()
            }
        }

        // Register first, then reconcile anything changed while Contacts was
        // hidden. A mutation during this refresh posts to the already-live
        // observer and replaces this task with a newer authoritative refresh.
        if hasLoadedContacts {
            scheduleSavedContactsRefresh()
        }
    }

    /// Stop listening for updates.
    public func stopListening() {
        updateTask?.cancel()
        updateTask = nil
        if let favoriteObserver {
            NotificationCenter.default.removeObserver(favoriteObserver)
            self.favoriteObserver = nil
        }
        favoriteRefreshTask?.cancel()
        favoriteRefreshTask = nil
    }

    /// Cancel any in-flight snapshot before starting a newer authoritative one.
    /// `refreshSavedContacts` checks cancellation after its repository await, so
    /// an older fetch cannot overwrite a newer favorite mutation.
    @MainActor
    private func scheduleSavedContactsRefresh() {
        favoriteRefreshTask?.cancel()
        favoriteRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.refreshSavedContacts()
                self.syncRelayState()
                self.errorMessage = nil
            } catch is CancellationError {
                // Superseded by a newer favorite mutation or listener teardown.
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
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
                || existing.isRelay != contact.isRelay
                || existing.aspect != contact.aspect {
                myContacts[myIndex] = existing.copy(
                    badgeType: contact.badgeType,
                    hopCount: contact.hopCount,
                    signalStrength: contact.signalStrength,
                    isRelay: contact.isRelay,
                    aspect: .some(contact.aspect)
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
        let merged = (networkAnnounces + pendingAnnounces)
            .sorted { $0.timestamp > $1.timestamp }
        pendingAnnounces.removeAll(keepingCapacity: true)
        networkAnnounces = merged
    }

    // MARK: - Public Methods

    /// Load contacts from storage. After the first full path snapshot, ordinary
    /// SwiftUI task reappearances refresh only saved-contact state; path updates
    /// remain live through the stream. Pull-to-refresh passes `force: true`.
    @MainActor
    public func loadContacts(force: Bool = false) async {
        guard !isContactsLoadInFlight else { return }

        isContactsLoadInFlight = true
        isLoading = true
        errorMessage = nil
        defer {
            isContactsLoadInFlight = false
            isLoading = false
        }

        do {
            if hasLoadedContacts && !force {
                try await refreshSavedContacts()
                syncRelayState()
                return
            }

            // Load saved contacts without publishing a second Network snapshot;
            // the full path snapshot below will reconcile favorite markers once.
            try await refreshSavedContacts(reconcileNetwork: false)

            // Build and mark the network snapshot off to the side, then publish
            // it once. This avoids repeatedly filtering thousands of contacts.
            if let pathTable = appServices.pathTable {
                let entries = await pathTable.allEntries()
                let loaded = entries
                    .filter { $0.isKnownDestination }
                    .map { Contact(from: $0) }
                    .sorted { $0.timestamp > $1.timestamp }
                networkAnnounces = markingSavedContacts(in: loaded)
            }

            // Drop only pending entries that the fresh snapshot covers. Keep
            // announces that arrived while the path-table await was suspended.
            let visibleIds = Set(networkAnnounces.map(\.id))
            pendingAnnounces.removeAll { visibleIds.contains($0.id) }

            enrichMyContactBadges()
            syncRelayState()

            // Aggregate-only diagnostics: never stringify contact arrays,
            // display names, or hashes on this hot path.
            let relayCount = networkAnnounces.lazy.filter(\.isRelay).count
            DiagLog.log(
                "[CONTACTS] loaded network=\(networkAnnounces.count) "
                + "relays=\(relayCount) saved=\(myContacts.count) "
                + "selected_relay_present=\(currentRelayContact != nil)"
            )

            hasLoadedContacts = true
            errorMessage = nil
        } catch is CancellationError {
            // View/task teardown is not a user-visible load failure.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh announces from the network.
    @MainActor
    public func refreshAnnounces() async {
        isLoading = true
        errorMessage = nil

        if let pathTable = appServices.pathTable {
            let entries = await pathTable.allEntries()
            let loaded = entries
                .filter { $0.isKnownDestination }
                .map { Contact(from: $0) }
                .sorted { $0.timestamp > $1.timestamp }
            networkAnnounces = markingSavedContacts(in: loaded)
        }
        // Drop only the pending entries the fresh path-table snapshot
        // already covers — see `loadContacts` for the same race
        // (handleNewPathEntry can interleave with the await above and
        // queue announces that aren't in the snapshot yet; a blanket
        // `removeAll()` would silently lose them).
        let visibleIds = Set(networkAnnounces.map(\.id))
        pendingAnnounces.removeAll { visibleIds.contains($0.id) }

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

    /// Toggle favorite/contact membership when the full `Contact` is known
    /// (e.g. from NodeDetailsView's toolbar star).
    ///
    /// Behaves like `toggleFavorite(for: contactId)` for the remove case, but
    /// when the peer is not currently in `myContacts` it adds it directly via
    /// `addToContacts(_:)` rather than relying on the peer also being present in
    /// `networkAnnounces`. This keeps the detail-screen star correct for a
    /// My-Contacts-only peer that was just removed and re-added, or any peer
    /// reached by a route that hasn't populated the announce arrays.
    ///
    /// Returns the authoritative saved state after persistence completes (true =
    /// the peer is now in `myContacts`). Callers with optimistic UI (e.g. the
    /// NodeDetailsView star) reconcile to this so a failed `addToContacts` or a
    /// rapid double-tap can't leave the UI showing "saved" when it isn't.
    @MainActor @discardableResult
    public func toggleFavorite(for contact: Contact) async -> Bool {
        if myContacts.contains(where: { $0.id == contact.id }) {
            // Already a saved contact — reuse the id-based remove path.
            toggleFavorite(for: contact.id)
        } else {
            // Not saved yet — add (creates conversation + setFavorite(true)).
            // addToContacts leaves myContacts untouched and sets errorMessage on
            // failure, so the membership check below reflects the real outcome.
            await addToContacts(contact)
        }
        return myContacts.contains(where: { $0.id == contact.id })
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

        do {
            let displayName = await SettingsRepository().getDisplayName()
            try await appServices.sendAllAnnounces(displayName: displayName)
            announceFeedback.show()
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
            let savedContact = contact.copy(isFavorite: true)
            if let existingIndex = myContacts.firstIndex(where: { $0.id == contact.id }) {
                myContacts[existingIndex] = savedContact
            } else {
                myContacts.append(savedContact)
            }

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

        // Bind the claimed delivery hash to the supplied public identity. A QR
        // code is explicit LXMF-delivery provenance only when these agree.
        guard let identity = try? Identity(publicKeyBytes: pubkeyData),
              Destination.hash(
                identity: identity,
                appName: "lxmf",
                aspects: ["delivery"]
              ) == hashData else {
            return nil
        }

        return (destinationHash: hashData, publicKey: pubkeyData)
    }

    /// Parsed manual contact input. The public key is present only for a
    /// cryptographically validated `lxma://` identity.
    public struct ParsedContactInput: Equatable, Sendable {
        public let destinationHash: Data
        public let publicKey: Data?
    }

    /// Parse Android-compatible manual contact input: either a complete,
    /// cryptographically bound `lxma://` identity or a 16-byte destination hash.
    public static func parseContactInput(_ input: String) -> ParsedContactInput? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("lxma://") {
            guard let parsed = parseLXMA(trimmed) else { return nil }
            return ParsedContactInput(
                destinationHash: parsed.destinationHash,
                publicKey: parsed.publicKey
            )
        }

        guard trimmed.count == 32,
              let destinationHash = hexToData(trimmed),
              destinationHash.count == 16 else {
            return nil
        }
        return ParsedContactInput(destinationHash: destinationHash, publicKey: nil)
    }

    /// Check if a contact with the given destination hash already exists.
    public func contactExists(_ destinationHash: Data) -> Bool {
        let hex = destinationHash.map { String(format: "%02x", $0) }.joined()
        return myContacts.contains(where: { $0.id == hex }) ||
               networkAnnounces.contains(where: { $0.id == hex && $0.isFavorite })
    }

    /// Add a contact from a QR code scan or deep link.
    @MainActor
    public func addContactFromQR(destinationHash: Data, publicKey: Data, nickname: String?) async -> Bool {
        let hex = destinationHash.map { String(format: "%02x", $0) }.joined()
        errorMessage = nil

        // Retain the already-validated public identity locally. This is a
        // cache write only: path discovery remains strictly send-triggered.
        let remembered = await appServices.backend?.core.rememberPeerIdentity(
            destHashHex: hex,
            publicKey: publicKey
        ) ?? false
        guard remembered else {
            errorMessage = "The contact identity could not be saved. Please try again."
            return false
        }
        return await addContactFromHash(
            destinationHash: destinationHash,
            nickname: nickname
        )
    }

    /// Add a contact from a destination hash without requesting a path. The
    /// existing outbound send gate resolves the peer identity only when needed.
    @MainActor
    public func addContactFromHash(destinationHash: Data, nickname: String?) async -> Bool {
        errorMessage = nil
        guard destinationHash.count == 16 else {
            errorMessage = "The destination hash must contain exactly 16 bytes."
            return false
        }

        do {
            try await persistFavoriteContact(
                destinationHash: destinationHash,
                nickname: nickname
            )
            return true
        } catch {
            errorMessage = "Failed to add contact: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    private func persistFavoriteContact(destinationHash: Data, nickname: String?) async throws {
        let hex = destinationHash.map { String(format: "%02x", $0) }.joined()
        guard !myContacts.contains(where: { $0.id == hex }) else { return }

        let announcedName = networkAnnounces.first(where: { $0.id == hex })?.displayName
            ?? pendingAnnounces.first(where: { $0.id == hex })?.displayName
        let trimmedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitNickname = trimmedNickname?.isEmpty == false ? trimmedNickname : nil

        try await messageRepository.ensureConversation(
            destinationHash,
            displayName: explicitNickname
        )
        if explicitNickname == nil,
           let announcedName,
           !announcedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await messageRepository.applyAnnouncedDisplayName(
                destinationHash,
                displayName: announcedName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        try await messageRepository.setFavorite(destinationHash, isFavorite: true)

        let persistedDisplayName = try await messageRepository
            .fetchConversations(for: [destinationHash])
            .first?
            .displayName

        let contact = Contact(
            id: hex,
            displayName: persistedDisplayName,
            identityHash: destinationHash,
            identityHashHex: hex,
            badgeType: .peer,
            hopCount: 0,
            signalStrength: 3,
            timestamp: Date(),
            isOnline: false,
            isFavorite: true,
            isRelay: false,
            aspect: "lxmf.delivery"
        )
        if let existingIndex = myContacts.firstIndex(where: { $0.id == hex }) {
            myContacts[existingIndex] = contact
        } else {
            myContacts.append(contact)
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

    /// Refresh favorites from the conversation store. Reappearance uses this
    /// lightweight path so changes made in Messaging are reflected without
    /// rebuilding every path-table contact.
    @MainActor @discardableResult
    private func refreshSavedContacts(reconcileNetwork: Bool = true) async throws -> Bool {
        savedContactsGeneration &+= 1
        let generation = savedContactsGeneration
        let conversations = try await messageRepository.fetchConversations()
        try Task.checkCancellation()
        guard generation == savedContactsGeneration else {
            return false
        }
        myContacts = conversations
            .filter { $0.isFavorite != 0 }
            .map { Contact(from: $0) }

        if reconcileNetwork {
            networkAnnounces = markingSavedContacts(in: networkAnnounces)
            pendingAnnounces = markingSavedContacts(in: pendingAnnounces)
            enrichMyContactBadges()
        }
        return true
    }

    /// Enrich myContacts from network announces.
    ///
    /// ConversationRecord has no badge / relay / hops / signal / aspect fields, so
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
            let aspectNeedsUpdate = announce.aspect != contact.aspect
            guard badgeNeedsUpdate || hopsNeedUpdate || aspectNeedsUpdate else { return contact }
            return contact.copy(
                badgeType: announce.badgeType,
                hopCount: announce.hopCount,
                signalStrength: announce.signalStrength,
                isRelay: announce.isRelay,
                aspect: .some(announce.aspect)
            )
        }
    }

    /// Mark network announces that already exist in my contacts without
    /// publishing an intermediate array (which would rebuild all filters).
    @MainActor
    private func markingSavedContacts(in contacts: [Contact]) -> [Contact] {
        let savedById = Dictionary(myContacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return contacts.map { contact in
            let saved = savedById[contact.id]
            let shouldBeFavorite = saved != nil
            let shouldBePinned = saved?.isPinned ?? false
            guard contact.isFavorite != shouldBeFavorite || contact.isPinned != shouldBePinned else {
                return contact
            }
            return contact.copy(
                isFavorite: saved != nil,
                isPinned: shouldBePinned
            )
        }
    }
}
