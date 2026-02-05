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
@available(iOS 17.0, *)
struct NetworkAnnouncesTab: View {
    // MARK: - Properties

    /// ViewModel providing network announces.
    @Bindable var viewModel: ContactsViewModel

    /// Called when a contact is selected.
    var onContactSelected: ((Contact) -> Void)?

    // MARK: - Body

    var body: some View {
        Group {
            if viewModel.filteredNetworkAnnounces.isEmpty {
                emptyState
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

    // MARK: - Announces List

    private var announcesList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.filteredNetworkAnnounces) { contact in
                    ContactCard(
                        contact: contact,
                        showGlobeIcon: true,
                        onFavoriteToggle: {
                            viewModel.toggleFavorite(for: contact.id)
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

#if DEBUG
@available(iOS 17.0, *)
#Preview("With Announces") {
    let viewModel = ContactsViewModel()
    Task {
        await viewModel.loadContacts()
    }

    return NetworkAnnouncesTab(viewModel: viewModel)
        .background(Color(white: 0.1))
}

@available(iOS 17.0, *)
#Preview("Empty State") {
    let viewModel = ContactsViewModel()

    return NetworkAnnouncesTab(viewModel: viewModel)
        .background(Color(white: 0.1))
}
#endif
