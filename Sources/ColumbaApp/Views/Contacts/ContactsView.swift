//
//  ContactsView.swift
//  Columba-iOS
//
//  Main contacts view with segmented picker tabs for My Contacts and Network.
//  Displays contact cards with search and filter capabilities.
//

import SwiftUI
import LXMFSwift

// MARK: - Contacts View

/// Main contacts screen with tabs and search.
///
/// Features:
/// - Segmented picker tabs: "My Contacts (N)" / "Network (N)"
/// - Search and filter icons in toolbar
/// - List of ContactCard items
/// - Section headers for grouped contacts
@available(iOS 17.0, macOS 14.0, *)
public struct ContactsView: View {
    // MARK: - Dependencies

    let appServices: AppServices
    let messageRepository: MessageRepository

    // MARK: - State

    /// ViewModel for contacts data.
    @State private var viewModel: ContactsViewModel?

    /// Whether search is active.
    @State private var isSearching = false

    /// Contact selected for node details navigation.
    @State private var selectedContact: Contact?

    /// Conversation to navigate to after "Start Chat".
    @State private var chatConversation: Conversation?

    /// Whether the QR scanner is shown.
    @State private var showQRScanner = false

    /// Contact scanned from QR code or deep link, shown in AddContactSheet.
    @State private var scannedContact: ScannedContact?

    /// Contact being edited for nickname.
    @State private var editingContact: Contact?

    /// Text field value for nickname editing.
    @State private var nicknameText: String = ""

    /// Pending deep link URL string to process.
    var pendingDeepLink: Binding<String?>?

    /// Called when a contact is selected.
    public var onContactSelected: ((Contact) -> Void)?

    // MARK: - Initialization

    public init(
        appServices: AppServices,
        messageRepository: MessageRepository,
        pendingDeepLink: Binding<String?>? = nil,
        onContactSelected: ((Contact) -> Void)? = nil
    ) {
        self.appServices = appServices
        self.messageRepository = messageRepository
        self.pendingDeepLink = pendingDeepLink
        self.onContactSelected = onContactSelected
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            if let vm = viewModel {
                VStack(spacing: 0) {
                    // Segmented picker
                    tabPicker(vm)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    // Search bar (if active)
                    if isSearching {
                        searchBar(vm)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    // Content
                    tabContent(vm)
                }
                .background(Theme.backgroundPrimary)
                .navigationTitle("Contacts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    toolbarContent(vm)
                }
                .navigationDestination(item: $selectedContact) { contact in
                    NodeDetailsView(
                        contact: contact,
                        appServices: appServices,
                        onStartChat: { contact in
                            startChat(with: contact)
                        }
                    )
                }
                .navigationDestination(item: $chatConversation) { conversation in
                    MessagingView(
                        conversation: conversation,
                        appServices: appServices,
                        messageRepository: messageRepository
                    )
                }
                .onAppear {
                    vm.startListening()
                    vm.syncRelayState()
                }
                .onDisappear {
                    vm.stopListening()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(Theme.accentColor)
        .task {
            if viewModel == nil {
                viewModel = ContactsViewModel(
                    appServices: appServices,
                    messageRepository: messageRepository
                )
            }
            await viewModel?.loadContacts()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showQRScanner) {
            if viewModel != nil {
                QRScannerView(
                    onScanned: { hash, pubKey in
                        showQRScanner = false
                        scannedContact = ScannedContact(destinationHash: hash, publicKey: pubKey)
                    },
                    onCancel: {
                        showQRScanner = false
                    }
                )
                .ignoresSafeArea()
            }
        }
        #endif
        .sheet(item: $scannedContact) { contact in
            if let vm = viewModel {
                AddContactSheet(
                    scannedContact: contact,
                    viewModel: vm,
                    onDismiss: { scannedContact = nil }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .alert("Edit Nickname", isPresented: Binding(
            get: { editingContact != nil },
            set: { if !$0 { editingContact = nil } }
        )) {
            TextField("Nickname", text: $nicknameText)
            Button("Save") {
                if let contact = editingContact {
                    viewModel?.updateNickname(for: contact.id, nickname: nicknameText)
                }
                editingContact = nil
            }
            Button("Clear", role: .destructive) {
                if let contact = editingContact {
                    viewModel?.updateNickname(for: contact.id, nickname: nil)
                }
                editingContact = nil
            }
            Button("Cancel", role: .cancel) {
                editingContact = nil
            }
        } message: {
            Text("Enter a custom name for this contact. Clear to use the announce name.")
        }
        .onChange(of: pendingDeepLink?.wrappedValue) { _, newValue in
            if let urlString = newValue, let parsed = ContactsViewModel.parseLXMA(urlString) {
                pendingDeepLink?.wrappedValue = nil
                scannedContact = ScannedContact(
                    destinationHash: parsed.destinationHash,
                    publicKey: parsed.publicKey
                )
            }
        }
    }

    // MARK: - Tab Picker

    private func tabPicker(_ vm: ContactsViewModel) -> some View {
        Picker("Tab", selection: Binding(
            get: { vm.selectedTab },
            set: { vm.selectedTab = $0 }
        )) {
            Text("My Contacts (\(vm.myContacts.count))")
                .tag(ContactsTab.myContacts)
            Text("Network (\(vm.networkAnnounces.count))")
                .tag(ContactsTab.network)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Search Bar

    private func searchBar(_ vm: ContactsViewModel) -> some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.gray)

            TextField("Search contacts...", text: Binding(
                get: { vm.searchText },
                set: { vm.searchText = $0 }
            ))
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(10)
        .background(Theme.backgroundTertiary)
        .cornerRadius(10)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(_ vm: ContactsViewModel) -> some View {
        switch vm.selectedTab {
        case .myContacts:
            myContactsTab(vm)
        case .network:
            NetworkAnnouncesTab(
                viewModel: vm,
                onContactSelected: { contact in
                    selectedContact = contact
                }
            )
        }
    }

    // MARK: - My Contacts Tab

    @ViewBuilder
    private func myContactsTab(_ vm: ContactsViewModel) -> some View {
        if vm.groupedMyContacts.isEmpty {
            myContactsEmptyState
        } else {
            myContactsList(vm)
        }
    }

    private var myContactsEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(.gray)

            Text("No Contacts")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("Add contacts from the Network tab\nor wait for announces")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func myContactsList(_ vm: ContactsViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(vm.groupedMyContacts, id: \.title) { group in
                    // Section header
                    sectionHeader(title: group.title)

                    // Contacts in section
                    ForEach(group.contacts) { contact in
                        ContactCard(
                            contact: contact,
                            showInterfaceIcon: false,
                            isSelectedRelay: group.title.contains("RELAY"),
                            onFavoriteToggle: {
                                vm.toggleFavorite(for: contact.id)
                            },
                            onTap: {
                                selectedContact = contact
                            },
                            onPin: {
                                vm.togglePin(for: contact.id)
                            },
                            onViewDetails: {
                                selectedContact = contact
                            },
                            onEditNickname: {
                                nicknameText = contact.displayName ?? ""
                                editingContact = contact
                            },
                            onRemove: {
                                vm.removeContact(contactId: contact.id)
                            }
                        )
                        .id("\(contact.id)-\(contact.isPinned)")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable {
            await vm.loadContacts()
        }
    }

    private func sectionHeader(title: String) -> some View {
        HStack(spacing: 6) {
            if title.contains("RELAY") {
                Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accentColor)
            } else if title == "PINNED" {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(title.contains("RELAY") ? Theme.accentColor : title == "PINNED" ? .yellow : Color.gray)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    // MARK: - Start Chat

    private func startChat(with contact: Contact) {
        Task {
            await viewModel?.addToContacts(contact)

            let conversation = Conversation(
                id: contact.id,
                destinationHash: contact.identityHash,
                displayName: contact.displayName,
                lastMessageTimestamp: Date(),
                lastMessagePreview: nil,
                unreadCount: 0,
                isFavorite: false
            )

            // Dismiss node details, then navigate to chat
            selectedContact = nil
            // Small delay to let navigation pop before pushing new destination
            try? await Task.sleep(for: .milliseconds(300))
            chatConversation = conversation
        }
    }

    private var toolbarButtons: some View {
        HStack(spacing: 16) {
            // Announce button
            Button {
                Task { await viewModel?.sendAnnounce() }
            } label: {
                if viewModel?.isAnnouncing == true {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: viewModel?.announceSuccess == true
                          ? "checkmark.circle.fill"
                          : "antenna.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(viewModel?.announceSuccess == true ? .green : Theme.accentColor)
                }
            }
            .disabled(viewModel?.isAnnouncing == true)
            .help("Send Announce")

            #if os(iOS)
            // QR scan button
            Button {
                showQRScanner = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title3)
            }
            #else
            // Paste contact button (macOS — no camera)
            Button {
                if let str = NSPasteboard.general.string(forType: .string),
                   let parsed = ContactsViewModel.parseLXMA(str) {
                    scannedContact = ScannedContact(
                        destinationHash: parsed.destinationHash,
                        publicKey: parsed.publicKey
                    )
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.title3)
            }
            .help("Add Contact from Clipboard")
            #endif

            // Search button
            Button {
                withAnimation {
                    isSearching.toggle()
                    if !isSearching {
                        viewModel?.searchText = ""
                    }
                }
            } label: {
                Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.title3)
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

    @ToolbarContentBuilder
    private func toolbarContent(_ vm: ContactsViewModel) -> some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
            toolbarButtons
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            toolbarButtons
        }
        #endif
    }
}

// MARK: - Preview

// Note: Preview disabled - requires AppServices and MessageRepository dependencies
// To preview, use the simulator with the full app.
