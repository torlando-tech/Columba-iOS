//
//  ChatsView.swift
//  Columba-iOS
//
//  Main chats view displaying the list of conversations.
//  Features dark theme, glass card styling, and smooth animations.
//

import SwiftUI
import LXMFSwift

/// Main chats view displaying conversation list.
///
/// Features:
/// - NavigationStack with "Chats" title and conversation count subtitle
/// - Search and refresh toolbar buttons
/// - List of ConversationRow items with glass card backgrounds
/// - Empty state when no conversations exist
/// - Pull-to-refresh support
@available(iOS 17.0, macOS 14.0, *)
struct ChatsView: View {
    // MARK: - Dependencies

    let appServices: AppServices
    let messageRepository: MessageRepository
    let notificationObserver: NotificationObserver

    // MARK: - State

    /// ViewModel managing conversation data.
    @State private var viewModel: ChatsViewModel?

    /// Controls search sheet presentation.
    @State private var isSearchPresented: Bool = false

    /// Controls the search text field focus.
    @FocusState private var isSearchFocused: Bool

    /// Contact selected for peer details navigation.
    @State private var selectedContact: Contact?

    /// Conversation to navigate to programmatically (e.g. from notification tap).
    @State private var notificationConversation: Conversation?

    /// Conversation pending deletion (confirmation alert).
    @State private var deletingConversation: Conversation?

    // MARK: - Theme Colors

    private var backgroundColor: Color { Theme.backgroundPrimary }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                backgroundColor.ignoresSafeArea()

                // Content
                if let vm = viewModel {
                    if vm.filteredConversations.isEmpty && !vm.isLoading {
                        emptyStateView
                    } else {
                        conversationListView(vm)
                    }

                    // Loading overlay
                    if vm.isLoading {
                        loadingOverlay
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Chats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Search button
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchPresented.toggle()
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                    }

                    // Refresh button — syncs from propagation node then reloads DB
                    Button {
                        guard viewModel?.isRefreshing != true else { return }
                        Task {
                            viewModel?.isRefreshing = true
                            await appServices.propagationManager?.syncNow()
                            await viewModel?.refreshConversations()
                            viewModel?.isRefreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(viewModel?.isRefreshing == true ? Theme.accentColor : Theme.textPrimary)
                            .rotationEffect(.degrees(viewModel?.isRefreshing == true ? 360 : 0))
                            .animation(
                                viewModel?.isRefreshing == true
                                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                                    : .default,
                                value: viewModel?.isRefreshing
                            )
                    }
                    .disabled(viewModel?.isRefreshing == true)
                }
            }
            #endif
            .safeAreaInset(edge: .top) {
                headerView
            }
            .navigationDestination(item: $selectedContact) { contact in
                NodeDetailsView(
                    contact: contact,
                    appServices: appServices,
                    onStartChat: nil
                )
            }
            .navigationDestination(item: $notificationConversation) { conversation in
                MessagingView(
                    conversation: conversation,
                    appServices: appServices,
                    messageRepository: messageRepository
                )
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accentColor)
        .task {
            // Initialize view model with dependencies
            if viewModel == nil {
                viewModel = ChatsViewModel(
                    repository: messageRepository,
                    notificationObserver: notificationObserver,
                    pathTable: appServices.pathTable
                )
            }
            await viewModel?.loadConversations()
        }
        .alert("Delete Conversation", isPresented: Binding(
            get: { deletingConversation != nil },
            set: { if !$0 { deletingConversation = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let conversation = deletingConversation {
                    Task { await viewModel?.deleteConversation(conversation) }
                }
                deletingConversation = nil
            }
            Button("Cancel", role: .cancel) {
                deletingConversation = nil
            }
        } message: {
            Text("This will permanently delete the conversation and all its messages.")
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            checkPendingNotification()
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPendingNotification()
        }
        #endif
        .onChange(of: viewModel?.filteredConversations) { _, _ in
            checkPendingNotification()
        }
    }

    /// Navigate to conversation from a tapped notification.
    private func checkPendingNotification() {
        guard let hash = NotificationService.pendingConversationHash,
              let vm = viewModel else { return }
        NotificationService.pendingConversationHash = nil
        if let conversation = vm.filteredConversations.first(where: { $0.id == hash }) {
            notificationConversation = conversation
        }
    }

    // MARK: - Subviews

    /// Custom header with subtitle showing conversation count.
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar (when active)
            if isSearchPresented, let vm = viewModel {
                searchBar(vm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Search bar for filtering conversations.
    @ViewBuilder
    private func searchBar(_ vm: ChatsViewModel) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.textDisabled)

                TextField("Search conversations", text: Binding(
                    get: { vm.searchQuery },
                    set: { vm.searchQuery = $0 }
                ))
                .foregroundColor(Theme.textPrimary)
                .focused($isSearchFocused)
                .submitLabel(.search)

                if !vm.searchQuery.isEmpty {
                    Button {
                        vm.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textDisabled)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.backgroundTertiary)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button("Cancel") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.searchQuery = ""
                    isSearchPresented = false
                    isSearchFocused = false
                }
            }
            .foregroundColor(Theme.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear {
            isSearchFocused = true
        }
    }

    /// List of conversation rows.
    @ViewBuilder
    private func conversationListView(_ vm: ChatsViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // Subtitle
                HStack {
                    Text(vm.conversationCountText)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

                // Conversation rows
                ForEach(vm.filteredConversations) { conversation in
                    NavigationLink {
                        // Navigate to messaging view
                        MessagingView(
                            conversation: conversation,
                            appServices: appServices,
                            messageRepository: messageRepository
                        )
                    } label: {
                        ConversationRow(
                            conversation: conversation,
                            onFavoriteToggle: {
                                vm.toggleFavorite(conversation)
                            },
                            onMarkUnread: {
                                vm.markUnread(conversation)
                            },
                            onViewDetails: {
                                selectedContact = Contact(
                                    id: conversation.id,
                                    displayName: conversation.displayName,
                                    identityHash: conversation.destinationHash,
                                    identityHashHex: conversation.id,
                                    badgeType: .peer,
                                    hopCount: 0,
                                    signalStrength: 0,
                                    timestamp: conversation.lastMessageTimestamp,
                                    isOnline: false,
                                    isFavorite: conversation.isFavorite,
                                    isPinned: false,
                                    isRelay: false,
                                    iconName: conversation.iconName,
                                    iconFgColor: conversation.iconFgColor,
                                    iconBgColor: conversation.iconBgColor
                                )
                            },
                            onRemoveContact: {
                                vm.toggleFavorite(conversation)
                            },
                            onDelete: {
                                deletingConversation = conversation
                            }
                        )
                    }
                    .buttonStyle(ConversationRowButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .refreshable {
            // Reload conversations from DB immediately, then kick off sync in background
            async let refresh: () = vm.refreshConversations()
            async let sync: () = {
                // Sync with timeout so pull-to-refresh doesn't hang
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await appServices.propagationManager?.syncNow()
                    }
                    group.addTask {
                        try? await Task.sleep(for: .seconds(15))
                    }
                    // Return when either finishes (timeout or sync)
                    await group.next()
                    group.cancelAll()
                }
            }()
            await refresh
            await sync
            // Reload again in case sync brought new messages
            await vm.refreshConversations()
        }
    }

    /// Empty state view when no conversations exist.
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            // Icon
            ZStack {
                Circle()
                    .fill(Theme.accentColor.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: "envelope.open")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(Theme.accentColor)
            }

            // Title
            Text("No Conversations Yet")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

            // Description
            Text("Share your Reticulum address with others to start receiving encrypted messages.")
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            // Refresh button — syncs from propagation node then reloads DB
            Button {
                Task {
                    await appServices.propagationManager?.syncNow()
                    await viewModel?.refreshConversations()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Theme.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 8)
        }
        .padding()
    }

    /// Loading overlay with progress indicator.
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)

            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: Theme.accentColor))
                .scaleEffect(1.2)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Button Style

/// Custom button style for conversation rows with press animation.
struct ConversationRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
