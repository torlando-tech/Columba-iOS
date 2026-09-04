//
//  ChatsView.swift
//  Columba-iOS
//
//  Main chats view displaying the list of conversations.
//  Features dark theme, glass card styling, and smooth animations.
//

import SwiftUI
import RNSAPI

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
    /// Cross-tab route from the Map tab's peer contact sheet: the tapped
    /// peer's destination hash. Consumed (and cleared) by this view once the
    /// conversation resolves - see `consumePeerChatRoute`. (No default: a
    /// `@Binding` property cannot take `= nil`, since the synthesized
    /// memberwise init parameter is `Binding<Data?>`, not `Data?`.)
    @Binding var pendingPeerChat: Data?

    // MARK: - State

    /// ViewModel managing conversation data.
    @State private var viewModel: ChatsViewModel?

    /// Controls search sheet presentation.
    @State private var isSearchPresented: Bool = false

    /// Controls the search text field focus.
    @FocusState private var isSearchFocused: Bool

    /// Contact selected for peer details navigation.
    @State private var selectedContact: Contact?

    /// Conversation to navigate to from a tapped notification. Owned by
    /// `checkPendingNotification` (sync) only.
    @State private var notificationConversation: Conversation?

    /// Conversation to navigate to from the Map tab's peer contact sheet.
    /// Owned by `consumePeerChatRoute` (async) only. Kept separate from
    /// `notificationConversation` so the asynchronous resolution can never
    /// clobber a navigation the user started from a notification (or vice
    /// versa) - see `consumePeerChatRoute`.
    @State private var peerConversation: Conversation?

    /// Set while the peer-chat route is resolving (between reading
    /// `pendingPeerChat` and pushing `peerConversation`). A notification
    /// tapped during that window must not overwrite the in-flight route.
    @State private var isResolvingPeerChat: Bool = false

    /// Conversation pending deletion (confirmation alert).
    @State private var deletingConversation: Conversation?

    /// Controls the propagation-sync status sheet. Presented only for user-initiated
    /// syncs (tapping the refresh button); background / periodic syncs run silently.
    @State private var isSyncSheetPresented: Bool = false

    /// The call whose codec sheet (call-again) is being presented. Drives the
    /// `.sheet(item:)` that presents `CodecSelectionSheet` from the Voice tab.
    @State private var showCodecSheetFor: VoiceCallDisplay?

    // MARK: - Theme Colors

    private var backgroundColor: Color { Theme.backgroundPrimary }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                backgroundColor.ignoresSafeArea()

                // Content
                segmentContent
            }
            .accessibilityIdentifier("screen_chats")
            .navigationTitle("Chats")
            #if os(iOS)
            // Compact inline title (matches ContactsView) so the Text|Voice
            // selector sits directly under a single nav-bar row. A `.large`
            // title reserves an extra title row, leaving an empty gap between
            // the search/refresh icons and the selector.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(backgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                chatsToolbarContent
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
            // Dedicated destination for the Map tab's peer-chat route so the
            // async push below can never fight the notification route for a
            // single `item:` binding.
            .navigationDestination(item: $peerConversation) { conversation in
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
                    pathTable: appServices.pathTable,
                    callHistory: appServices.callHistoryRepository,
                    localIdentityHashHex: appServices.identity?.hexHash
                )
            }
            await viewModel?.loadConversations()
            // Voice segment history (issue #167)
            await viewModel?.loadVoiceHistory()
            // A route may exist before this view mounts (MainTabView holds it
            // until ChatsView consumes it), so `.onChange` alone is not enough.
            await consumePeerChatRoute()
        }
        // Track the live call so the Voice list can mark the matching card
        // "In progress", and reload when a call ends (a new history row lands).
        .onChange(of: appServices.callManager?.activeCallAttemptId) { _, newValue in
            viewModel?.activeCallAttemptId = newValue
            if newValue == nil { Task { await viewModel?.loadVoiceHistory() } }
        }
        .onChange(of: pendingPeerChat) { _, _ in
            Task { await consumePeerChatRoute() }
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
        // Show the sync status sheet only for user-initiated syncs — the refresh button
        // sets `isSyncSheetPresented`. Background / periodic syncs (including Model B's
        // NE-driven periodic sync) update `syncState` silently without popping the sheet.
        // Once presented, the sheet observes `syncState` for live progress and stays up
        // through the terminal phase so the user sees the result, then dismisses manually.
        .sheet(isPresented: $isSyncSheetPresented) {
            // Container reads `syncState` in its own view body (not just inside this
            // closure) so SwiftUI Observation reliably re-renders the sheet on every
            // transfer-state change — live progress and the terminal result.
            SyncStatusSheetContainer(manager: appServices.propagationManager)
        }
        // Call-again: present the codec/quality picker, then dial the chosen peer
        // (issue #167). Guard-lets the remote hash Data so an invalid stored hash
        // (nil) simply does nothing rather than dialing a bogus number.
        .sheet(item: $showCodecSheetFor) { display in
            CodecSelectionSheet { profile in
                showCodecSheetFor = nil
                #if os(iOS)
                if let destination = display.record.remoteIdentityHashData {
                    appServices.callManager?.initiateCall(
                        destinationHash: destination,
                        profile: profile,
                        peerDisplayName: display.peerName
                    )
                }
                #endif
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkPendingNotification() }
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkPendingNotification() }
        }
        #endif
        .onChange(of: viewModel?.conversations) { _, _ in
            Task { await checkPendingNotification() }
        }
    }

    /// Navigate to conversation from a tapped notification.
    ///
    /// Deferred while a Map-tab peer-chat route is resolving: the peer
    /// route owns navigation for that in-flight window and re-runs this
    /// check when it settles, so the tap is not lost. (Once the peer
    /// conversation is pushed, a new notification simply stacks on top of
    /// it - ordinary `item:` navigation behavior, no shared state.)
    ///
    /// Lookups use the unfiltered `conversations` list so an active search
    /// query cannot hide the tapped conversation. The pending slot is only
    /// consumed by the tap that still owns it (checked again after the
    /// async refresh), so a stale continuation never opens an older
    /// conversation over a newer tap, and a row not yet in storage leaves
    /// the slot intact for the next list change or activation to retry.
    @MainActor
    private func checkPendingNotification() async {
        guard let hash = NotificationService.pendingConversationHash,
              let vm = viewModel else { return }
        if isResolvingPeerChat {
            // The map route owns navigation for this window. Leave the
            // pending hash in place - `consumePeerChatRoute` re-runs this
            // check when it finishes resolving, so the notification still
            // opens (stacking on top of the peer conversation).
            return
        }
        // Unfiltered lookup: an active search query must not hide the
        // conversation the notification points at. No suspension between
        // this read and the clear below, so the claim is race-free.
        if let conversation = vm.conversations.first(where: { $0.id == hash }) {
            NotificationService.pendingConversationHash = nil
            notificationConversation = conversation
            return
        }
        // The row may not be in the in-memory snapshot yet (a message that
        // just arrived): re-read from storage, then look again.
        await vm.refreshConversations()
        // Consume and route only if this tap still owns the pending slot.
        // A newer tap that replaced the slot during the refresh is routed
        // by its own check; a stale continuation must not open the older
        // conversation (or briefly replace the newer route). Re-check route
        // ownership too: `refreshConversations()` above is a suspension, so a
        // map peer route may have started while it ran. It owns navigation
        // for its window and re-runs this check at settle
        // (consumePeerChatRoute), so the deferred tap is still delivered -
        // it just must not race the peer push now.
        guard let conversation = vm.conversations.first(where: { $0.id == hash }),
              NotificationService.pendingConversationHash == hash,
              !isResolvingPeerChat else {
            // The slot now belongs to a newer tap (or a peer route owns
            // navigation). If a newer tap owns it, route it now - a no-op
            // refresh fires no list-change callback, so waiting for the
            // next trigger would strand it. If a peer route owns it, this
            // returns immediately and the route delivers the tap at settle.
            if NotificationService.pendingConversationHash != nil,
               NotificationService.pendingConversationHash != hash {
                await checkPendingNotification()
            }
            // Otherwise the row is still not in storage, or a peer route is
            // mid-resolution: leave the slot intact so the peer-route
            // settle, the next list change, or an activation retries
            // instead of dropping the tap.
            return
        }
        NotificationService.pendingConversationHash = nil
        notificationConversation = conversation
    }

    /// Consume the Map tab's peer-chat route: resolve the peer's conversation
    /// (creating the row if the peer has only ever shared telemetry and never
    /// exchanged a message) and push it via the dedicated `peerConversation`
    /// route - never the shared notification route, which a concurrent
    /// notification tap could be using. Clears `pendingPeerChat` before doing
    /// async work so a repeat `.onChange` or view rebuild can't double-open
    /// the conversation.
    @MainActor
    private func consumePeerChatRoute() async {
        guard let hash = pendingPeerChat, !isResolvingPeerChat else { return }
        // Clear first: the route is one-shot.
        pendingPeerChat = nil
        // Flag the in-flight window so a notification tapped mid-resolution
        // (checkPendingNotification) defers instead of competing.
        isResolvingPeerChat = true

        // Resolve the conversation. A telemetry-only peer may have no row yet,
        // so `ensureConversation` creates it, then we refetch.
        var record = try? await messageRepository.fetchConversation(hash)
        if record == nil {
            try? await messageRepository.ensureConversation(hash, displayName: nil)
            record = try? await messageRepository.fetchConversation(hash)
        }

        let conversation: Conversation
        if let record {
            conversation = Conversation(from: record)
        } else {
            // Ensure failed (DB error) - still open a shell conversation so the
            // Message tap lands somewhere coherent rather than silently
            // dropping the user's intent.
            conversation = Conversation(
                id: hash.toHex(),
                destinationHash: hash,
                lastMessageTimestamp: Date()
            )
        }
        // Peer route owns this state exclusively, so no concurrent writer can
        // overwrite the push (unlike the shared notification route).
        peerConversation = conversation
        isResolvingPeerChat = false

        // A notification tapped during the resolution window was deferred
        // (its pending hash left in place). Deliver it now that the peer
        // route has settled, so it stacks on top instead of waiting for an
        // unrelated activation or list change.
        await checkPendingNotification()

        // A second Map Message tapped while this route was resolving was
        // rejected by the in-flight guard and left in `pendingPeerChat`.
        // Its only other trigger (`.onChange`) needs a fresh change, so
        // retry here at settle - otherwise it is stranded. Bounded: each
        // pass clears a non-nil slot, so the recursion stops when the
        // queue is empty.
        if pendingPeerChat != nil {
            await consumePeerChatRoute()
        }
    }

    // MARK: - Subviews

    /// The Text | Voice content for the Chats screen (issue #167). Extracted
    /// from `body` so the type-checker doesn't have to hold the segment switch
    /// plus the whole list/empty/overlay expressions in one pass (it times out).
    @ViewBuilder
    private var segmentContent: some View {
        if let vm = viewModel {
            switch vm.selectedSegment {
            case .voice:
                VoiceHistoryView(
                    viewModel: vm,
                    appServices: appServices,
                    onCallAgain: { showCodecSheetFor = $0 },
                    onClear: { Task { await vm.clearVoiceHistory() } }
                )
            case .text:
                if vm.filteredConversations.isEmpty && !vm.isLoading {
                    emptyStateView
                } else {
                    conversationListView(vm)
                }
                // Loading overlay
                if vm.isLoading {
                    loadingOverlay
                }
            }
        } else {
            ProgressView()
        }
    }

    /// Trailing toolbar content, segment-aware (issue #167). Extracted from
    /// `.toolbar { }` in `body` so the type-checker isn't given the whole
    /// toolbar + search/sync expression in one go (it times out on that).
    /// Voice shows the clear-history menu; Text keeps the existing search/sync.
    @ToolbarContentBuilder
    private var chatsToolbarContent: some ToolbarContent {
        if viewModel?.selectedSegment == .voice {
            // Voice segment: search + clear-history (search/sync-once are
            // text-only; Voice search filters the call history live).
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearchPresented.toggle()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                .accessibilityIdentifier("voice_search_toggle")

                Menu {
                    Button("Clear history", role: .destructive) {
                        Task { await viewModel?.clearVoiceHistory() }
                    }
                    .accessibilityIdentifier("call_history_clear")
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
            }
        } else {
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
                    // User explicitly asked to sync → surface the status sheet.
                    isSyncSheetPresented = true
                    Task {
                        viewModel?.isRefreshing = true
                        await appServices.propagationManager?.syncNow(userInitiated: true)
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
    }

    /// Custom header with subtitle showing conversation count.
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Text | Voice subtab split (issue #167)
            if let vm = viewModel {
                ChatsSegmentSelector(selection: Binding(
                    get: { vm.selectedSegment },
                    set: { vm.selectedSegment = $0 }
                ))
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            // Search bar (when active)
            if isSearchPresented, let vm = viewModel {
                if vm.selectedSegment == .voice {
                    voiceSearchBar(vm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    searchBar(vm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
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

    /// Search bar for filtering the Voice history (issue #167). Mirrors the
    /// Text search bar but binds `voiceSearchQuery`; the query filters live
    /// (the Voice list re-derives from `voiceRecords` — see the `.task(id:)`
    /// in the view body), so no reload is needed on each keystroke.
    @ViewBuilder
    private func voiceSearchBar(_ vm: ChatsViewModel) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.textDisabled)

                TextField(String(localized: "Search calls"), text: Binding(
                    get: { vm.voiceSearchQuery },
                    set: { vm.voiceSearchQuery = $0 }
                ))
                .foregroundColor(Theme.textPrimary)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("voice_search_field")

                if !vm.voiceSearchQuery.isEmpty {
                    Button {
                        vm.voiceSearchQuery = ""
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

            Button(String(localized: "Cancel")) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.voiceSearchQuery = ""
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
                        await appServices.propagationManager?.syncNow(userInitiated: true)
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
                // User explicitly asked to sync → surface the status sheet.
                isSyncSheetPresented = true
                Task {
                    await appServices.propagationManager?.syncNow(userInitiated: true)
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

// MARK: - Sync Status Sheet Container

/// Bridges the app's `@Observable` `PropagationNodeManager` to the pure, value-typed
/// `SyncStatusBottomSheet`. Reading `manager.syncState` inside this view's `body`
/// (rather than only inside the parent's `.sheet` content closure) guarantees SwiftUI
/// Observation re-renders the sheet whenever the transfer state changes, so live
/// progress and the terminal result always appear.
@available(iOS 17.0, macOS 14.0, *)
private struct SyncStatusSheetContainer: View {
    let manager: PropagationNodeManager?

    var body: some View {
        SyncStatusBottomSheet(state: manager?.syncState ?? PropagationTransferState())
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
