//
//  NodeDetailsView.swift
//  Columba-iOS
//
//  Node details screen showing contact info cards and a destination-type action.
//  Navigated to by tapping a contact card in ContactsView.
//

import SwiftUI
import RNSAPI

/// Node details screen showing identity info and a primary action.
///
/// Layout:
/// - Header: Large identicon, display name, online/expired status badge
/// - Action selected from the exact destination aspect: Chat for LXMF delivery,
///   Call for LXST telephony, Browse Site for NomadNet, and relay controls only
///   for enabled LXMF propagation announces.
/// - Details cards: Destination hash, hop count, last heard/expires timestamps
@available(iOS 17.0, macOS 14.0, *)
struct NodeDetailsView: View {
    // MARK: - Properties

    /// Contact to display details for.
    let contact: Contact

    /// AppServices for path table lookup.
    let appServices: AppServices

    /// Called when "Start Chat" is tapped; receives the contact.
    /// Only rendered for non-NomadNet contacts when this callback is non-nil.
    var onStartChat: ((Contact) -> Void)?

    /// Called when "Call" is tapped for an lxst.telephony destination.
    var onStartCall: ((Contact) -> Void)?

    /// Called when "Browse Site" is tapped on a NomadNet site contact.
    /// Only rendered for `.node` badge contacts when this callback is non-nil.
    var onBrowseSite: ((Contact) -> Void)?

    /// Called when the top-right star is tapped; receives the displayed contact
    /// and returns the **authoritative** favorite/saved state after persistence
    /// completes. The view reconciles its optimistic star to this return value,
    /// so a failed save (no rollback) or a rapid double-tap can't leave the star
    /// out of sync with what was actually persisted. The star is only rendered
    /// when this callback is non-nil, so each parent decides which ViewModel
    /// persists the change — mirroring `onStartChat`/`onBrowseSite`.
    var onToggleFavorite: ((Contact) async -> Bool)?

    // MARK: - State

    @State private var expiresDate: Date?
    @State private var interfaceName: String?
    @State private var propagationInfo: PropagationNodeInfo?
    @State private var isCurrentRelay: Bool = false
    /// Live snapshot seeded from the parent-supplied `contact` and refreshed
    /// whenever the path table reports a newer entry for this destination.
    /// All bindings in the view read from this so the badge transitions from
    /// "No Active Path" to "Online" the moment an announce arrives.
    @State private var liveContact: Contact?
    /// Source of truth for the toolbar star, kept separate from `liveContact`
    /// because `mergedContact`/`applyOfflineState` always re-derive
    /// `isFavorite` from the original seed; binding the star to
    /// `displayedContact.isFavorite` would make it snap back on the next path
    /// poll. Seeded in `.task` and toggled optimistically.
    @State private var isFavorite: Bool = false
    /// Guards against rapid double-taps: the star is disabled while a toggle is
    /// in flight, so two queued persistence tasks can't race the optimistic flip.
    @State private var isTogglingFavorite: Bool = false
    @Environment(\.dismiss) private var dismiss

    /// Effective contact for view bindings: live snapshot if available,
    /// otherwise the parent-supplied initial snapshot.
    private var displayedContact: Contact {
        liveContact ?? contact
    }

    /// Polling cadence for path-table observation. Path updates are bursty and
    /// uncommon (announces, not heartbeats), so a 1.5 s tick is plenty
    /// responsive without burning cycles.
    private static let pollInterval: Duration = .milliseconds(1500)

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                if !displayedContact.isOnline {
                    expiredHint
                }
                if displayedContact.destinationAspect == .lxmfPropagation,
                   propagationInfo?.enabled == true {
                    setAsRelayButton
                } else {
                    primaryActionButton
                }
                detailsSection
                if propagationInfo != nil {
                    propagationDetailsSection
                }
            }
            .padding(16)
        }
        .background(Theme.backgroundPrimary.ignoresSafeArea())
        .navigationTitle("Node Details")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if onToggleFavorite != nil {
                // `.primaryAction` renders top-right on iOS (like Android's
                // TopAppBar star) while staying valid on the macOS target;
                // `.topBarTrailing` is iOS-only.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard !isTogglingFavorite, let onToggleFavorite else { return }
                        // Flip optimistically for snappiness, then reconcile to
                        // the authoritative persisted state the callback returns
                        // (covers add-failure rollback + double-tap races).
                        isFavorite.toggle()
                        isTogglingFavorite = true
                        let c = displayedContact
                        Task {
                            let persisted = await onToggleFavorite(c)
                            isFavorite = persisted
                            isTogglingFavorite = false
                        }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Theme.accentColor : Theme.textSecondary)
                    }
                    .disabled(isTogglingFavorite)
                    .accessibilityLabel(isFavorite ? "Remove from contacts" : "Save contact")
                }
            }
        }
        .task(id: contact.id) {
            // Seed the live snapshot from the parent-supplied contact so the
            // first render uses whatever the parent already knew, then keep
            // it in sync with the path table. Always overwrite — if the user
            // navigated to a different contact on the same view instance,
            // `liveContact` still holds the previous contact's data and would
            // bleed through until the polling loop's first apply.
            liveContact = contact
            // Seed the toolbar star from the parent-supplied contact. Keyed on
            // `contact.id`, so navigating to a different node re-seeds it.
            isFavorite = contact.isFavorite
            // Also reset auxiliary state so the previous contact's metadata
            // (relay button, interface name, expiry date) doesn't render for
            // contact B during the first path-table lookup.
            expiresDate = nil
            interfaceName = nil
            propagationInfo = nil
            isCurrentRelay = false
            await loadPathDetails()
            await observePathUpdates()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        let c = displayedContact
        return VStack(spacing: 12) {
            // Large profile icon (MDI or identicon fallback)
            ProfileIcon(
                iconName: c.iconName,
                foregroundColor: c.iconFgColor,
                backgroundColor: c.iconBgColor,
                fallbackHash: c.identityHash,
                size: 80
            )

            // Display name
            Text(c.resolvedDisplayName)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)

            // Status badge
            statusBadge
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var statusBadge: some View {
        let isOnline = displayedContact.isOnline
        return HStack(spacing: 6) {
            Circle()
                .fill(isOnline ? Theme.success : Theme.error)
                .frame(width: 8, height: 8)

            Text(isOnline ? "Online" : "No Active Path")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(isOnline ? Theme.success : Theme.error)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill((isOnline ? Theme.success : Theme.error).opacity(0.15))
        }
    }

    // MARK: - Missing Path Hint

    /// Help text shown when no current path is cached. Browsing remains passive;
    /// the messaging backend requests and awaits a path only when Send is used.
    private var expiredHint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("No active path")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)

                Text("Columba will request a path automatically when you send a message.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                .fill(Theme.backgroundSecondary)
        }
    }

    // MARK: - Primary Action Button

    /// Renders "Call" for telephony, "Browse Site" for NomadNet, or
    /// "Start Chat" for messaging destinations. Returns an `EmptyView` when
    /// the matching callback is absent.
    @ViewBuilder
    private var primaryActionButton: some View {
        let c = displayedContact
        if c.destinationAspect == .lxstTelephony, let onStartCall {
            actionButton(
                icon: "phone.fill",
                title: "Call"
            ) {
                onStartCall(c)
            }
        } else if c.destinationAspect == .nomadNetworkNode, let onBrowseSite {
            actionButton(
                icon: "globe.americas",
                title: "Browse Site"
            ) {
                onBrowseSite(c)
            }
        } else if c.destinationAspect == .lxmfDelivery, let onStartChat {
            actionButton(
                icon: "bubble.left.fill",
                title: "Start Chat"
            ) {
                onStartChat(c)
            }
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                    .fill(Theme.accentGradient)
            }
        }
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        let c = displayedContact
        return VStack(spacing: 12) {
            detailRow(
                icon: "number",
                label: "Destination Hash",
                value: c.identityHashHex,
                isMonospace: true,
                isCopyable: true
            )

            detailRow(
                icon: "point.3.connected.trianglepath.dotted",
                label: "Network Distance",
                value: c.hopDescription
            )

            detailRow(
                icon: "antenna.radiowaves.left.and.right",
                label: "Interface",
                value: interfaceName ?? "Unknown"
            )

            // TimelineView re-evaluates the relative portion ("5 min ago")
            // every 60 seconds so it ticks forward while the view is open
            // instead of freezing at first-render time. Use `c.timestamp`
            // (the live-contact swap from this PR) so a fresh announce
            // also refreshes the value, not just the relative phrasing.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                detailRow(
                    icon: "clock.arrow.circlepath",
                    label: "Last Heard",
                    value: formattedLastHeard(c.timestamp, now: context.date)
                )
            }

            if let expires = expiresDate {
                detailRow(
                    icon: "clock.badge.xmark",
                    label: "Expires",
                    value: formattedDate(expires)
                )
            }
        }
    }

    private func detailRow(
        icon: String,
        label: String,
        value: String,
        isMonospace: Bool = false,
        isCopyable: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Theme.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                if isMonospace {
                    Text(value)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                } else {
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            Spacer()

            if isCopyable {
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = value
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                        .foregroundStyle(Theme.accentColor)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .glassCard()
    }

    // MARK: - Set as Relay Button

    private var setAsRelayButton: some View {
        Button {
            guard let propManager = appServices.propagationManager else { return }
            Task { @MainActor in
                if isCurrentRelay {
                    if await propManager.clearSelection() {
                        isCurrentRelay = false
                    }
                } else if await propManager.selectNode(hash: contact.identityHash) {
                    propManager.autoSelectEnabled = false
                    isCurrentRelay = true
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrentRelay ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                Text(isCurrentRelay ? "Current Relay" : "Set as My Relay")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                if isCurrentRelay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                        .fill(Theme.success)
                } else {
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusMedium)
                        .fill(Theme.accentGradient)
                }
            }
        }
    }

    // MARK: - Propagation Details

    private var propagationDetailsSection: some View {
        VStack(spacing: 12) {
            if let info = propagationInfo {
                detailRow(
                    icon: "tray.full",
                    label: "Per Transfer Limit",
                    value: "\(info.perTransferLimit) messages"
                )

                detailRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Per Sync Limit",
                    value: "\(info.perSyncLimit) messages"
                )

                if info.stampCost > 0 {
                    detailRow(
                        icon: "seal",
                        label: "Stamp Cost",
                        value: "\(info.stampCost)"
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    /// Combined relative + absolute formatting for the "Last Heard" card.
    ///
    /// Renders as "5 min ago  •  Apr 26, 2026 at 2:03 PM" so the user gets an
    /// at-a-glance recency cue plus the precise wall-clock timestamp.
    ///
    /// The `now` parameter lets callers (e.g. `TimelineView`) drive the
    /// "relative" reference point so the string ticks forward over time.
    private func formattedLastHeard(_ date: Date, now: Date = Date()) -> String {
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: now)
        let absolute = Self.dateFormatter.string(from: date)
        return "\(relative)  \u{2022}  \(absolute)"
    }

    private func loadPathDetails() async {
        guard let pathTable = appServices.pathTable else { return }
        if let entry = await pathTable.lookup(destinationHash: contact.identityHash) {
            await applyPathEntry(entry)
        } else {
            // No path entry — the polling loop only clears these on a
            // transition (online → expired), so on the initial load /
            // pull-to-refresh we have to drop stale path metadata
            // explicitly to avoid showing an "Expires" row or relay
            // button for a destination the path table doesn't know.
            // Also flip the cached isOnline so a manual refresh
            // immediately reflects the pruned state instead of waiting
            // for the next 1.5 s poll tick.
            applyOfflineState()
        }
        // Check if this is the currently selected relay
        if let propManager = appServices.propagationManager {
            isCurrentRelay = propManager.selectedNodeHash == contact.identityHash
        }
    }

    /// Drop all path-derived metadata and rebuild `liveContact` with
    /// `isOnline = false`. Called when the path table reports no entry
    /// for this destination — both from the polling loop (transition
    /// case) and `loadPathDetails` (initial load / pull-to-refresh).
    private func applyOfflineState() {
        expiresDate = nil
        interfaceName = nil
        propagationInfo = nil
        guard let stale = liveContact, stale.isOnline else { return }
        liveContact = Contact(
            id: stale.id,
            displayName: stale.displayName,
            identityHash: stale.identityHash,
            identityHashHex: stale.identityHashHex,
            badgeType: stale.badgeType,
            hopCount: stale.hopCount,
            signalStrength: stale.signalStrength,
            timestamp: stale.timestamp,
            isOnline: false,
            isFavorite: stale.isFavorite,
            isPinned: stale.isPinned,
            isRelay: stale.isRelay,
            iconName: stale.iconName,
            iconFgColor: stale.iconFgColor,
            iconBgColor: stale.iconBgColor,
            interfaceId: stale.interfaceId,
            aspect: stale.aspect
        )
    }

    /// Apply a freshly-fetched `PathEntry` to the view state.
    ///
    /// Updates `expiresDate`, `interfaceName`, `propagationInfo`, and merges
    /// path-derived fields (status, hop count, timestamp, interface, aspect,
    /// badge) into `liveContact` while preserving user-customized fields
    /// (display name override, icon, favorite/pin) from the seed contact.
    private func applyPathEntry(_ entry: PathEntry) async {
        expiresDate = entry.expires
        if !entry.interfaceId.isEmpty {
            if let transport = appServices.transport {
                interfaceName = await transport.getInterfaceName(for: entry.interfaceId)
                    ?? entry.interfaceId
            } else {
                interfaceName = entry.interfaceId
            }
        } else {
            // Re-announce arrived without interface attribution — drop
            // the previously-resolved name so the row reverts to
            // "Unknown" instead of pinning to a stale value.
            interfaceName = nil
        }
        if entry.destinationAspect == .lxmfPropagation,
           let appData = entry.appData {
            propagationInfo = PropagationNodeInfo.parse(from: appData)
        } else {
            // Clear stale info when a re-announce drops the propagation
            // payload — otherwise the "Set as Relay" button keeps showing
            // for nodes that have since changed roles.
            propagationInfo = nil
        }
        liveContact = mergedContact(seed: contact, entry: entry)
    }

    /// Build a Contact that takes path-derived live fields from `entry` while
    /// preserving user-customized fields (custom display name, icon overrides,
    /// favorite/pin state) from the parent-supplied seed.
    private func mergedContact(seed: Contact, entry: PathEntry) -> Contact {
        let pathContact = Contact(from: entry)
        return Contact(
            id: seed.id,
            // Prefer the user-set custom name; fall back to the latest announce
            // name when the seed didn't have one.
            displayName: seed.displayName ?? pathContact.displayName,
            identityHash: seed.identityHash,
            identityHashHex: seed.identityHashHex,
            // Take live fields from the path entry.
            badgeType: pathContact.badgeType,
            hopCount: pathContact.hopCount,
            signalStrength: pathContact.signalStrength,
            timestamp: pathContact.timestamp,
            isOnline: pathContact.isOnline,
            // Preserve user state from the seed.
            isFavorite: seed.isFavorite,
            isPinned: seed.isPinned,
            isRelay: pathContact.isRelay,
            // Preserve any custom icon overrides set by the user.
            iconName: seed.iconName ?? pathContact.iconName,
            iconFgColor: seed.iconFgColor ?? pathContact.iconFgColor,
            iconBgColor: seed.iconBgColor ?? pathContact.iconBgColor,
            interfaceId: pathContact.interfaceId,
            aspect: pathContact.aspect
        )
    }

    /// Poll the path table for changes to this destination while the view is
    /// alive. We poll instead of subscribing to `pathTable.pathUpdates`
    /// because that AsyncStream only retains a single continuation: a second
    /// subscriber would silently displace `ContactsViewModel`'s subscription
    /// and break the network announces UI. Polling is consistent with
    /// `NetworkStatusViewModel` and is cheap (one in-memory dict lookup per
    /// tick). `.task(id:)` cancels this loop automatically when the view
    /// disappears or the contact changes.
    private func observePathUpdates() async {
        guard let pathTable = appServices.pathTable else { return }
        var lastTimestamp: Date? = liveContact?.timestamp ?? contact.timestamp
        var lastIsOnline: Bool = liveContact?.isOnline ?? contact.isOnline
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { break }
            let entry = await pathTable.lookup(destinationHash: contact.identityHash)
            // Compute live online state from the cached entry's expiry vs. now.
            // This makes the badge flip Online -> Expired the instant the
            // cached expires deadline crosses `now`, without waiting for a new
            // announce. Using `>=` (not strict `>`) on the timestamp guards
            // against duplicate-timestamp announces (clock collisions / fast
            // arriving announces) where a user-visible field changed.
            let nowIsOnline = entry.map { Date() < $0.expires } ?? false
            let timestampChanged = entry?.timestamp != lastTimestamp
            let onlineChanged = nowIsOnline != lastIsOnline
            if timestampChanged || onlineChanged {
                if let entry {
                    await applyPathEntry(entry)
                } else if onlineChanged {
                    // Path entry was pruned. applyPathEntry only runs
                    // with a non-nil entry, so without this branch
                    // `liveContact.isOnline` would stay `true` while
                    // the sentinel `lastIsOnline` flips to `false`,
                    // suppressing the next attempt — badge stuck on
                    // "Online" forever.
                    applyOfflineState()
                }
                lastTimestamp = entry?.timestamp
                lastIsOnline = nowIsOnline
            }
        }
    }

}
