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
                .foregroundStyle(.white)

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
            .tint(AppTheme.accentColor)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Filtered Empty State

    private var filteredEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.announceFilter == .relays
                  ? "server.rack" : "person.2")
                .font(.system(size: 48))
                .foregroundStyle(.gray)

            Text("No \(viewModel.announceFilter.rawValue) Found")
                .font(.headline)
                .foregroundStyle(.white)

            Text("Try a different filter or wait\nfor new announces")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(AnnounceFilter.allCases, id: \.self) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.announceFilter = filter
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(.subheadline)
                        .fontWeight(viewModel.announceFilter == filter ? .semibold : .regular)
                        .foregroundStyle(viewModel.announceFilter == filter ? .white : .gray)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background {
                            if viewModel.announceFilter == filter {
                                Capsule().fill(AppTheme.accentColor)
                            } else {
                                Capsule().fill(Color.white.opacity(0.08))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Announces List

    private var announcesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.filteredNetworkAnnounces) { contact in
                    ContactCard(
                        contact: contact,
                        showGlobeIcon: true,
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
