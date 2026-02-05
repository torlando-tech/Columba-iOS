//
//  ContactsView.swift
//  Columba-iOS
//
//  Main contacts view with segmented picker tabs for My Contacts and Network.
//  Displays contact cards with search and filter capabilities.
//

import SwiftUI

// MARK: - App Theme

/// App theming constants.
enum AppTheme {
    /// Primary accent color (matches Columba Android).
    /// Hex: #6750A4 (light purple/violet)
    static let accentColor = Color(red: 0.404, green: 0.314, blue: 0.643)
}

// MARK: - Contacts View

/// Main contacts screen with tabs and search.
///
/// Features:
/// - Segmented picker tabs: "My Contacts (N)" / "Network (N)"
/// - Search and filter icons in toolbar
/// - List of ContactCard items
/// - Section headers for grouped contacts
@available(iOS 17.0, *)
public struct ContactsView: View {
    // MARK: - Properties

    /// ViewModel for contacts data.
    @State private var viewModel = ContactsViewModel()

    /// Whether search is active.
    @State private var isSearching = false

    /// Called when a contact is selected.
    public var onContactSelected: ((Contact) -> Void)?

    // MARK: - Initialization

    public init(onContactSelected: ((Contact) -> Void)? = nil) {
        self.onContactSelected = onContactSelected
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented picker
                tabPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Search bar (if active)
                if isSearching {
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                // Content
                tabContent
            }
            .background(Color(white: 0.1))
            .navigationTitle("Contacts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            #endif
            .task {
                await viewModel.loadContacts()
            }
        }
        .tint(AppTheme.accentColor)
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        Picker("Tab", selection: $viewModel.selectedTab) {
            Text("My Contacts (\(viewModel.myContacts.count))")
                .tag(ContactsTab.myContacts)
            Text("Network (\(viewModel.networkAnnounces.count))")
                .tag(ContactsTab.network)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.gray)

            TextField("Search contacts...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .myContacts:
            myContactsTab
        case .network:
            NetworkAnnouncesTab(
                viewModel: viewModel,
                onContactSelected: onContactSelected
            )
        }
    }

    // MARK: - My Contacts Tab

    private var myContactsTab: some View {
        Group {
            if viewModel.filteredMyContacts.isEmpty {
                myContactsEmptyState
            } else {
                myContactsList
            }
        }
    }

    private var myContactsEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(.gray)

            Text("No Contacts")
                .font(.headline)
                .foregroundStyle(.white)

            Text("Add contacts from the Network tab\nor wait for announces")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var myContactsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.groupedMyContacts, id: \.title) { group in
                    // Section header
                    sectionHeader(title: group.title)

                    // Contacts in section
                    ForEach(group.contacts) { contact in
                        ContactCard(
                            contact: contact,
                            showGlobeIcon: false,
                            onFavoriteToggle: {
                                viewModel.toggleFavorite(for: contact.id)
                            },
                            onTap: {
                                onContactSelected?(contact)
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable {
            await viewModel.loadContacts()
        }
    }

    private func sectionHeader(title: String) -> some View {
        HStack(spacing: 8) {
            if title.contains("RELAY") {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.pink)
            }

            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(title.contains("RELAY") ? Color.pink : Color.gray)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                // Search button
                Button {
                    withAnimation {
                        isSearching.toggle()
                        if !isSearching {
                            viewModel.searchText = ""
                        }
                    }
                } label: {
                    Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.title3)
                }

                // Filter button (for network tab)
                if viewModel.selectedTab == .network {
                    Button {
                        // Filter action
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.title3)
                    }

                    // Volume/mute button
                    Button {
                        // Mute action
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.title3)
                    }
                }

                // Add button (for my contacts tab)
                if viewModel.selectedTab == .myContacts {
                    Button {
                        // Add contact action
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                    }
                }

                // More options
                Menu {
                    Button("Sort by Name", action: {})
                    Button("Sort by Recent", action: {})
                    Divider()
                    Button("Show Offline", action: {})
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                }
            }
        }
    }
    #endif
}

// MARK: - Preview

#if DEBUG
@available(iOS 17.0, *)
#Preview {
    ContactsView()
        .preferredColorScheme(.dark)
}
#endif
