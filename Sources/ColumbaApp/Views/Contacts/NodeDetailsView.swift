//
//  NodeDetailsView.swift
//  Columba-iOS
//
//  Node details screen showing contact info cards and a Start Chat button.
//  Navigated to by tapping a contact card in ContactsView.
//

import SwiftUI
import LXMFSwift
import ReticulumSwift

/// Node details screen showing identity info and a primary action.
///
/// Layout:
/// - Header: Large identicon, display name, online/expired status badge
/// - Action: "Start Chat" or "Browse Site" button (accent gradient, full width).
///   For NomadNet sites (`badgeType == .node`), shows "Browse Site" when
///   `onBrowseSite` is provided; otherwise shows "Start Chat" when
///   `onStartChat` is provided. If neither callback is provided for the
///   relevant badge type, no primary action is rendered.
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

    /// Called when "Browse Site" is tapped on a NomadNet site contact.
    /// Only rendered for `.node` badge contacts when this callback is non-nil.
    var onBrowseSite: ((Contact) -> Void)?

    // MARK: - State

    @State private var expiresDate: Date?
    @State private var interfaceName: String?
    @State private var propagationInfo: PropagationNodeInfo?
    @State private var isCurrentRelay: Bool = false
    /// Live snapshot seeded from the parent-supplied `contact` and refreshed
    /// whenever the path table reports a newer entry for this destination.
    /// All bindings in the view read from this so the badge transitions from
    /// "Expired" to "Online" the moment an announce arrives.
    @State private var liveContact: Contact?
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
                if propagationInfo != nil {
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
        .refreshable {
            await refreshFromNetwork()
        }
        .task(id: contact.id) {
            // Seed the live snapshot from the parent-supplied contact so the
            // first render uses whatever the parent already knew, then keep
            // it in sync with the path table. Always overwrite — if the user
            // navigated to a different contact on the same view instance,
            // `liveContact` still holds the previous contact's data and would
            // bleed through until the polling loop's first apply.
            liveContact = contact
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

            Text(isOnline ? "Online" : "Expired")
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

    // MARK: - Expired Hint

    /// Help text shown when a contact's path entry has expired (no recent
    /// announce on the network). Most common right after scanning a QR — the
    /// destination hash is known but the network hasn't yet relayed an
    /// announce we can use to route to them.
    private var expiredHint: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for an announce")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)

                Text("This contact hasn't announced themselves to the network recently. Ask them to send an announce from their app, or wait for one to arrive automatically.")
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

    /// Renders "Browse Site" for NomadNet sites or "Start Chat" otherwise.
    /// Returns an `EmptyView` when no callback is provided for the contact's
    /// badge type — the parent owns whether the action should appear.
    @ViewBuilder
    private var primaryActionButton: some View {
        let c = displayedContact
        if c.badgeType == .node, let onBrowseSite {
            actionButton(
                icon: "globe.americas",
                title: "Browse Site"
            ) {
                onBrowseSite(c)
            }
        } else if c.badgeType != .node, let onStartChat {
            actionButton(
                icon: "bubble.left.fill",
                title: "Start Chat"
            ) {
                onStartChat(c)
            }
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        let isOnline = displayedContact.isOnline
        return Button(action: action) {
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
        .disabled(!isOnline)
        .opacity(isOnline ? 1.0 : 0.5)
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
            if let propManager = appServices.propagationManager {
                if isCurrentRelay {
                    Task { await propManager.clearSelection() }
                    isCurrentRelay = false
                } else {
                    propManager.autoSelectEnabled = false
                    Task { await propManager.selectNode(hash: contact.identityHash) }
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
        }
        // Check if this is the currently selected relay
        if let propManager = appServices.propagationManager {
            isCurrentRelay = propManager.selectedNodeHash == contact.identityHash
        }
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
        }
        if let appData = entry.appData {
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
                } else if onlineChanged, let stale = liveContact {
                    // Path entry was removed (expired and pruned).
                    // applyPathEntry runs only with a non-nil entry,
                    // so without this branch `liveContact.isOnline`
                    // would stay `true` indefinitely while the
                    // sentinel `lastIsOnline` flips to `false` and
                    // suppresses the next attempt — badge stuck on
                    // "Online" forever. `Contact.isOnline` is `let`,
                    // so rebuild the value with the flipped flag.
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
                    expiresDate = nil
                }
                lastTimestamp = entry?.timestamp
                lastIsOnline = nowIsOnline
            }
        }
    }

    /// Pull-to-refresh handler. Re-resolves path data and, if the transport
    /// supports it, sends an active path request to probe for the contact.
    private func refreshFromNetwork() async {
        // Trigger an active probe so the network has a chance to surface a
        // fresh announce before we re-read the table. This is best-effort —
        // if no node responds, we just re-display whatever the cache holds.
        if let transport = appServices.transport {
            await transport.requestPath(for: contact.identityHash)
        }
        // Give the path request a brief window to land before reloading.
        try? await Task.sleep(for: .milliseconds(500))
        await loadPathDetails()
    }
}
