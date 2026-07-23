//
//  NetworkAnnouncesTab.swift
//  Columba-iOS
//
//  Network tab showing all announces from the mesh network.
//  Displays discovered peers with globe icon and "Peer" badges.
//

import SwiftUI
import RNSAPI

/// Network announces tab content.
///
/// Shows all announces from the network with:
/// - Globe icon on cards
/// - "Peer" badges
/// - Pull-to-refresh
/// - Empty state when no announces
@available(iOS 17.0, macOS 14.0, *)
struct NetworkAnnouncesTab: View {
    // MARK: - Properties

    /// ViewModel providing network announces.
    @Bindable var viewModel: ContactsViewModel

    /// Called when a contact is selected.
    var onContactSelected: ((Contact) -> Void)?

    /// Keep the live SwiftUI hierarchy bounded even when the path table holds
    /// thousands of destinations. Additional rows are appended near the end.
    private static let pageSize = 100
    @State private var visibleLimit = NetworkAnnouncesTab.pageSize

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Hoist the pill to body-level so it's visible regardless
            // of whether the visible list is empty / filter-empty /
            // populated. Otherwise an active filter or a fresh-empty
            // network tab would suppress the pill even though new
            // matching announces are pending.
            if !viewModel.filteredPendingAnnounces.isEmpty {
                showNewBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            // Always show filter bar when there are any announces
            if !viewModel.networkAnnounces.isEmpty {
                filterBar
            }

            if viewModel.networkAnnounces.isEmpty {
                emptyState
            } else if viewModel.filteredNetworkAnnounces.isEmpty {
                filteredEmptyState
            } else {
                announcesList
            }
        }
        .onChange(of: viewModel.announceFilter) { _, _ in resetVisibleWindow() }
        .onChange(of: viewModel.interfaceFilter) { _, _ in resetVisibleWindow() }
        .onChange(of: viewModel.searchText) { _, _ in resetVisibleWindow() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(.gray)

            Text("No Network Announces")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Pull to refresh or wait for\npeers to announce themselves")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    await viewModel.refreshAnnounces()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accentColor)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Filtered Empty State

    private var filteredEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filteredEmptyIcon)
                .font(.system(size: 48))
                .foregroundStyle(.gray)

            Text("No Matching Announces")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Try a different filter or wait\nfor new announces")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var filteredEmptyIcon: String {
        switch viewModel.announceFilter {
        case .relays: return "server.rack"
        case .audio: return "phone.down"
        case .sites: return "globe.americas"
        case .peers: return "person.2"
        case .all: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 6) {
            // Aspect filter row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AnnounceFilter.allCases, id: \.self) { filter in
                        filterCapsule(
                            label: filter.rawValue,
                            icon: aspectIcon(for: filter),
                            isSelected: viewModel.announceFilter == filter
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.announceFilter = filter
                            }
                        }
                    }
                    Spacer()
                }
            }

            // Interface filter row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(InterfaceFilter.allCases, id: \.self) { filter in
                        filterCapsule(
                            label: filter.rawValue,
                            icon: interfaceIcon(for: filter),
                            mdiIcon: filter == .ble ? "bluetooth" : nil,
                            lucideIcon: filter == .rnode ? "antenna" : nil,
                            isSelected: viewModel.interfaceFilter == filter
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.interfaceFilter = filter
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func filterCapsule(label: String, icon: String?, mdiIcon: String? = nil, lucideIcon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let lucideIcon, let ch = Lucide.character(for: lucideIcon) {
                    Text(String(ch))
                        .font(.custom(Lucide.fontName, size: 12))
                } else if let mdiIcon, let ch = MaterialDesignIcons.character(for: mdiIcon) {
                    Text(String(ch))
                        .font(.custom(MaterialDesignIcons.fontName, size: 12))
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(label)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .foregroundStyle(isSelected ? .white : .gray)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(Theme.accentColor)
                } else {
                    Capsule().fill(ThemeManager.shared.isDarkMode ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func aspectIcon(for filter: AnnounceFilter) -> String? {
        switch filter {
        case .all: return nil
        case .peers: return "person.2"
        case .audio: return "phone"
        case .sites: return "globe.americas"
        case .relays: return "server.rack"
        }
    }

    private func interfaceIcon(for filter: InterfaceFilter) -> String? {
        switch filter {
        case .all: return nil
        case .tcp: return "globe"
        case .wifi: return "wifi"
        case .ble: return nil // MDI bluetooth icon used instead
        case .rnode: return nil // Lucide antenna glyph used instead
        }
    }

    // MARK: - Announces List

    private var announcesList: some View {
        let filtered = viewModel.filteredNetworkAnnounces
        let visible = filtered.prefix(visibleLimit)

        return ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(visible) { contact in
                    ContactCard(
                        contact: contact,
                        showInterfaceIcon: true,
                        onFavoriteToggle: {
                            // Route through `toggleFavorite` so an
                            // already-favorited announce can be un-starred
                            // without first switching to the My Contacts
                            // tab. Calling `addToContacts` directly was a
                            // no-op when the contact was already saved.
                            viewModel.toggleFavorite(for: contact.id)
                        },
                        onTap: {
                            onContactSelected?(contact)
                        }
                    )
                }

                if visibleLimit < filtered.count {
                    ProgressView()
                        .padding(.vertical, 12)
                        .onAppear {
                            loadNextPage(totalCount: filtered.count)
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await viewModel.refreshAnnounces()
        }
    }

    private func loadNextPage(totalCount: Int) {
        visibleLimit = min(visibleLimit + Self.pageSize, totalCount)
    }

    private func resetVisibleWindow() {
        visibleLimit = Self.pageSize
    }

    /// Tappable banner shown above the list while new announces are buffered.
    /// Lets the user merge them in on demand instead of having the visible
    /// list reorder under their finger as new announces stream in.
    private var showNewBanner: some View {
        // Use the filter-aware count so the pill matches what will
        // actually appear in the list after a flush.
        let count = viewModel.filteredPendingAnnounces.count
        return Button {
            withAnimation(.easeOut(duration: 0.25)) {
                viewModel.flushPendingAnnounces()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                Text("Show \(count) new announce\(count == 1 ? "" : "s")")
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(Theme.accentColor)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

// Note: Preview disabled - requires AppServices and MessageRepository dependencies
// To preview, use the simulator with the full app.
