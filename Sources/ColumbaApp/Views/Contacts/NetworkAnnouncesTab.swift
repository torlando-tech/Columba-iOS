//
//  NetworkAnnouncesTab.swift
//  Columba-iOS
//
//  Network tab showing all announces from the mesh network.
//  Displays discovered peers with globe icon and "Peer" badges.
//

import SwiftUI

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

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
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
        case .nodes: return "globe"
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

    private func filterCapsule(label: String, icon: String?, mdiIcon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let mdiIcon, let ch = MaterialDesignIcons.character(for: mdiIcon) {
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
        case .nodes: return "globe"
        case .relays: return "server.rack"
        }
    }

    private func interfaceIcon(for filter: InterfaceFilter) -> String? {
        switch filter {
        case .all: return nil
        case .tcp: return "globe"
        case .wifi: return "wifi"
        case .ble: return nil // MDI bluetooth icon used instead
        case .rnode: return "antenna.radiowaves.left.and.right"
        }
    }

    // MARK: - Announces List

    private var announcesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.filteredNetworkAnnounces) { contact in
                    ContactCard(
                        contact: contact,
                        showInterfaceIcon: true,
                        onFavoriteToggle: {
                            Task { await viewModel.addToContacts(contact) }
                        },
                        onTap: {
                            onContactSelected?(contact)
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await viewModel.refreshAnnounces()
        }
    }
}

// MARK: - Preview

// Note: Preview disabled - requires AppServices and MessageRepository dependencies
// To preview, use the simulator with the full app.
